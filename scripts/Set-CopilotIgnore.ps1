#Requires -Version 5.1
<#
.SYNOPSIS
    Injects or updates the copilot-context-policy .copilotignore in Git repositories.

.DESCRIPTION
    - Discovers Git repositories under -RootPath and/or takes explicit roots (-RepositoryPath or pipeline).
    - Composes the file from stack profiles declared in templates/profiles.json: 'common' always applies,
      and every other profile (dotnet, node, python, java, go, ...) applies when one of its marker files
      is found in the repository, or when it is forced with -Stack.
    - Missing file: created with FileMode.CreateNew (never replaces an existing file).
    - Existing file: nothing is rewritten; only the missing rules are appended, preserving the file's
      encoding (BOM / UTF-16) and line endings. Idempotent.
    - Honors local opt-outs declared as '# @disable <pattern>'.
    - Failures are isolated per repository; exit code 1 if any repository fails. Supports -WhatIf/-Confirm.
    - This file is intentionally ASCII-only: Windows PowerShell 5.1 reads BOM-less .ps1 files as ANSI.

.PARAMETER RootPath
    One or more folders that contain repositories, searched up to -DiscoveryDepth levels deep.

.PARAMETER RepositoryPath
    Explicit repository roots. Accepts pipeline input (strings or DirectoryInfo). Blank lines and lines
    starting with '#' are ignored, so a plain repos.txt file can be piped in.

.PARAMETER Stack
    Profiles to apply instead of auto-detection (for example: dotnet, node). 'common' is always applied.
    Also restricts -ContentExclusionOutFile to these profiles.

.PARAMETER TemplateDirectory
    Folder that holds profiles.json and the profile templates. Defaults to ../templates relative to this script.

.PARAMETER DiscoveryDepth
    Maximum folder depth below -RootPath where repositories are searched for.

.PARAMETER StackSearchDepth
    Maximum folder depth inside a repository where stack marker files are searched for.

.PARAMETER ContentExclusionOutFile
    Also writes the organization-level GitHub Copilot Content Exclusion YAML: the union of all profiles
    (or of -Stack), because Content Exclusion applies it to every repository.

.PARAMETER PassThru
    Emits one result object per repository.

.EXAMPLE
    ./Set-CopilotIgnore.ps1 -RootPath C:\src -WhatIf

.EXAMPLE
    Get-Content .\repos.txt | ./Set-CopilotIgnore.ps1 -PassThru | Export-Csv .\rollout.csv -NoTypeInformation

.EXAMPLE
    ./Set-CopilotIgnore.ps1 -RepositoryPath C:\src\portal -Stack dotnet, node

.EXAMPLE
    ./Set-CopilotIgnore.ps1 -ContentExclusionOutFile .\content-exclusion.org.yml

.LINK
    https://github.com/alfredoagrar/copilot-context-policy
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string[]] $RootPath,

    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName')]
    [string[]] $RepositoryPath,

    [string[]] $Stack,

    [string] $TemplateDirectory,

    [ValidateRange(0, 10)]
    [int] $DiscoveryDepth = 2,

    [ValidateRange(0, 10)]
    [int] $StackSearchDepth = 4,

    [string] $ContentExclusionOutFile,

    [switch] $PassThru
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $FileName  = '.copilotignore'
    $SourceUrl = 'https://github.com/alfredoagrar/copilot-context-policy'
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $SkipDirs  = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('.git', '.vs', '.idea', 'bin', 'obj', 'node_modules', 'packages', 'TestResults', 'artifacts'),
        [System.StringComparer]::OrdinalIgnoreCase)
    Write-Verbose "Discovery depth: $DiscoveryDepth; stack search depth: $StackSearchDepth"

    function Test-IsRule([string] $Line) {
        $t = $Line.Trim()
        return ($t.Length -gt 0 -and -not $t.StartsWith('#'))
    }

    function Test-GitRoot([string] $Path) {
        $git = [System.IO.Path]::Combine($Path, '.git')   # a folder, or a file in worktrees/submodules
        return ([System.IO.Directory]::Exists($git) -or [System.IO.File]::Exists($git))
    }

    function Get-ChildDirectory([string] $Path) {
        try {
            foreach ($dir in [System.IO.Directory]::EnumerateDirectories($Path)) {
                if (-not $SkipDirs.Contains([System.IO.Path]::GetFileName($dir))) { $dir }
            }
        }
        catch { Write-Verbose "Skipping '$Path': $($_.Exception.Message)" }
    }

    function Find-GitRepository([string] $Root) {
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(@($Root, 0))
        while ($queue.Count -gt 0) {
            $dir, $depth = $queue.Dequeue()
            if (Test-GitRoot $dir) { $dir; continue }          # never descend into a repository
            if ($depth -lt $DiscoveryDepth) {
                foreach ($sub in (Get-ChildDirectory $dir)) { $queue.Enqueue(@($sub, ($depth + 1))) }
            }
        }
    }

    function Get-RepositoryStack([string] $Path) {
        # Depth-bounded BFS over file names; stops early once every profile has been detected.
        $found = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(@($Path, 0))
        while ($queue.Count -gt 0 -and $found.Count -lt $DetectableCount) {
            $dir, $depth = $queue.Dequeue()
            try {
                foreach ($file in [System.IO.Directory]::EnumerateFiles($dir)) {
                    $name = [System.IO.Path]::GetFileName($file)
                    foreach ($stackProfile in $Profiles) {
                        if ($stackProfile.Always -or $found.Contains($stackProfile.Name)) { continue }
                        foreach ($marker in $stackProfile.Markers) {
                            if ($name -like $marker) { [void]$found.Add($stackProfile.Name); break }
                        }
                    }
                }
            }
            catch { Write-Verbose "Skipping '$dir': $($_.Exception.Message)" }
            if ($depth -lt $StackSearchDepth) {
                foreach ($sub in (Get-ChildDirectory $dir)) { $queue.Enqueue(@($sub, ($depth + 1))) }
            }
        }
        return @($found)
    }

    function Select-StackProfile([string[]] $Names) {
        # 'always' profiles plus the requested ones, in manifest order.
        @($Profiles | Where-Object { $_.Always -or ($Names -contains $_.Name) })
    }

    function Read-ProfileTemplate([string] $Path) {
        $lines   = [System.IO.File]::ReadAllLines($Path, $Utf8NoBom)
        $blocks  = [System.Collections.Generic.List[object]]::new()
        $current = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ($line.Trim().Length -eq 0) {
                if ($current.Count -gt 0) { $blocks.Add($current.ToArray()); $current.Clear() }
            }
            else { $current.Add($line) }
        }
        if ($current.Count -gt 0) { $blocks.Add($current.ToArray()) }
        # The leading comment-only block documents the template file itself and is not copied.
        if ($blocks.Count -gt 0 -and @($blocks[0] | Where-Object { Test-IsRule $_ }).Count -eq 0) { $blocks.RemoveAt(0) }
        $rules = @($lines | Where-Object { Test-IsRule $_ } | ForEach-Object { $_.Trim() })
        return [pscustomobject]@{ Blocks = $blocks.ToArray(); Rules = $rules }
    }

    function Read-TextFile([string] $Path) {
        # Detects a BOM (UTF-8/UTF-16/UTF-32); assumes UTF-8 when there is none.
        $reader = [System.IO.StreamReader]::new($Path, $Utf8NoBom, $true)
        try {
            $text = $reader.ReadToEnd()
            return [pscustomobject]@{ Text = $text; Encoding = $reader.CurrentEncoding }
        }
        finally { $reader.Dispose() }
    }

    function Write-TextFile([string] $Path, [string] $Text, [System.Text.Encoding] $Encoding, [System.IO.FileMode] $Mode) {
        # Encoding.GetBytes never emits a BOM, so appending never touches the start of the file.
        $bytes  = $Encoding.GetBytes($Text)
        $stream = [System.IO.File]::Open($Path, $Mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try { $stream.Write($bytes, 0, $bytes.Length) }
        finally { $stream.Dispose() }
    }

    function ConvertTo-RuleSet([string] $Text) {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($line in ($Text -split '\r?\n')) {
            if (Test-IsRule $line) { [void]$set.Add($line.Trim()) }
            elseif ($line -match '^\s*#\s*@disable\s+(\S.*?)\s*$') { [void]$set.Add($Matches[1]) }
        }
        return , $set   # the comma stops PowerShell from enumerating the HashSet
    }

    function Get-NewFileText([object[]] $Selected) {
        $names = ($Selected | ForEach-Object { $_.Name }) -join ', '
        $sb = [System.Text.StringBuilder]::new()
        $header = @(
            '# =============================================================================='
            "#  .copilotignore - copilot-context-policy $PolicyVersion"
            "#  Stacks: $names"
            "#  Source: $SourceUrl"
            '# ------------------------------------------------------------------------------'
            '#  Keeps GitHub Copilot from using versioned files that burn tokens without'
            '#  improving suggestions. Rules use the gitignore subset that Copilot Content'
            '#  Exclusion also understands: explicit "**/" or "/" anchor, no "!" negation.'
            '#  Set-CopilotIgnore.ps1 only appends missing rules. To opt out of a rule,'
            '#  delete it and add a line "# @disable <pattern>".'
            '# ==============================================================================')
        foreach ($line in $header) { [void]$sb.Append($line).Append("`n") }
        foreach ($stackProfile in $Selected) {
            foreach ($block in $stackProfile.Blocks) {
                [void]$sb.Append("`n")
                foreach ($line in $block) { [void]$sb.Append($line).Append("`n") }
            }
        }
        [void]$sb.Append("`n# --- Repository-specific rules -------------------------------------------------`n")
        [void]$sb.Append("# Add root-anchored paths below (e.g. /src/Legacy/big.json).`n")
        return $sb.ToString()
    }

    function Get-MissingBlock([object[]] $Selected, [System.Collections.Generic.HashSet[string]] $ExistingRules) {
        # Walks the selected templates block by block (blocks are separated by blank lines) and keeps
        # a block's comments only when at least one of its rules is missing.
        $lines = [System.Collections.Generic.List[string]]::new()
        $added = 0
        foreach ($stackProfile in $Selected) {
            foreach ($block in $stackProfile.Blocks) {
                $pending = @($block | Where-Object { (Test-IsRule $_) -and -not $ExistingRules.Contains($_.Trim()) })
                if ($pending.Count -eq 0) { continue }
                foreach ($line in $block) {
                    if (Test-IsRule $line) {
                        if (-not $ExistingRules.Add($line.Trim())) { continue }   # already present
                        $added++
                    }
                    $lines.Add($line)
                }
                $lines.Add('')
            }
        }
        if ($lines.Count -gt 0) { $lines.RemoveAt($lines.Count - 1) }
        return [pscustomobject]@{ Lines = $lines.ToArray(); Count = $added }
    }

    function Get-RepositoryPlan([string] $Path) {
        # Decides what to do with a repository without touching the disk.
        $plan = [pscustomobject]@{
            Status = ''; Stacks = ''; Target = $null; Mode = $null; Text = $null; Encoding = $null
            Operation = $null; RulesAdded = 0; Detail = "Policy $PolicyVersion"
        }

        if (-not (Test-GitRoot $Path)) {
            $plan.Status = 'Skipped'; $plan.Detail = 'Not a Git repository root'
            return $plan
        }

        $names    = if ($Stack) { @($Stack) } else { @(Get-RepositoryStack $Path) }
        $selected = @(Select-StackProfile $names)
        $plan.Stacks = ($selected | ForEach-Object { $_.Name }) -join ','

        $plan.Target = [System.IO.Path]::Combine($Path, $FileName)
        if ([System.IO.Directory]::Exists($plan.Target)) { throw "'$($plan.Target)' is a directory." }

        if (-not [System.IO.File]::Exists($plan.Target)) {
            $distinct = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($stackProfile in $selected) { foreach ($rule in $stackProfile.Rules) { [void]$distinct.Add($rule) } }
            $plan.Status = 'Created'; $plan.Mode = 'CreateNew'; $plan.Operation = "Create ($($plan.Stacks))"
            $plan.Text = Get-NewFileText -Selected $selected; $plan.Encoding = $Utf8NoBom; $plan.RulesAdded = $distinct.Count
            return $plan
        }

        $existing = Read-TextFile $plan.Target
        $missing  = Get-MissingBlock -Selected $selected -ExistingRules (ConvertTo-RuleSet $existing.Text)
        if ($missing.Count -eq 0) {
            $plan.Status = 'UpToDate'
            return $plan
        }

        $eol = if ($existing.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $sb  = [System.Text.StringBuilder]::new()
        if ($existing.Text.Length -gt 0) {
            if (-not $existing.Text.EndsWith("`n")) { [void]$sb.Append($eol) }
            [void]$sb.Append($eol)
        }
        [void]$sb.Append("# >>> copilot-context-policy $PolicyVersion [$($plan.Stacks)] | $(Get-Date -Format 'yyyy-MM-dd') | appended by Set-CopilotIgnore.ps1 >>>").Append($eol)
        foreach ($line in $missing.Lines) { [void]$sb.Append($line).Append($eol) }
        [void]$sb.Append('# <<< copilot-context-policy <<<').Append($eol)

        $plan.Status = 'Updated'; $plan.Mode = 'Append'; $plan.Operation = "Append $($missing.Count) missing rule(s) ($($plan.Stacks))"
        $plan.Text = $sb.ToString(); $plan.Encoding = $existing.Encoding; $plan.RulesAdded = $missing.Count
        return $plan
    }

    # --- Load and validate the profile manifest and templates ------------------------------
    if (-not $TemplateDirectory) {
        if (-not $PSScriptRoot) { throw 'Cannot resolve the script location; pass -TemplateDirectory.' }
        $TemplateDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates'
    }
    $manifestPath = Join-Path $TemplateDirectory 'profiles.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Profile manifest not found: $manifestPath" }
    $manifestFile = (Resolve-Path -LiteralPath $manifestPath).ProviderPath
    $manifest     = [System.IO.File]::ReadAllText($manifestFile, $Utf8NoBom) | ConvertFrom-Json
    $PolicyVersion = [string]$manifest.version

    $Profiles = @(foreach ($entry in $manifest.profiles) {
        $templateFile = Join-Path (Split-Path -Parent $manifestFile) ([string]$entry.template)
        if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) { throw "Template for profile '$($entry.name)' not found: $templateFile" }
        $template = Read-ProfileTemplate $templateFile
        if ($template.Rules.Count -eq 0) { throw "Template '$templateFile' contains no rules." }
        [pscustomobject]@{
            Name    = [string]$entry.name
            Always  = [bool]$entry.always
            Markers = @($entry.markers)
            Blocks  = $template.Blocks
            Rules   = $template.Rules
        }
    })
    if ($Profiles.Count -eq 0) { throw "No profiles declared in $manifestFile." }
    $DetectableCount = @($Profiles | Where-Object { -not $_.Always }).Count

    $knownStacks = @($Profiles | ForEach-Object { $_.Name })
    foreach ($name in @($Stack)) {
        if ($name -and $knownStacks -notcontains $name) { throw "Unknown stack '$name'. Known stacks: $($knownStacks -join ', ')." }
    }

    $pendingPaths = [System.Collections.Generic.List[string]]::new()
}

process {
    foreach ($item in @($RepositoryPath)) {
        if ([string]::IsNullOrWhiteSpace($item) -or $item.TrimStart().StartsWith('#')) { continue }
        $pendingPaths.Add($item.Trim())
    }
}

end {
    # --- Optional export to the official mechanism (GitHub Copilot Content Exclusion) -----
    if ($ContentExclusionOutFile) {
        $exported = if ($Stack) { @(Select-StackProfile @($Stack)) } else { $Profiles }
        $rules = [System.Collections.Generic.List[string]]::new()
        $seenRules = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($stackProfile in $exported) {
            foreach ($rule in $stackProfile.Rules) { if ($seenRules.Add($rule)) { $rules.Add($rule) } }
        }

        $outFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ContentExclusionOutFile)
        $yaml = [System.Text.StringBuilder]::new()
        [void]$yaml.Append("# GitHub Copilot > Content exclusion (organization level). copilot-context-policy $PolicyVersion.`n")
        [void]$yaml.Append("# Stacks: $(($exported | ForEach-Object { $_.Name }) -join ', '). Generated by Set-CopilotIgnore.ps1; do not edit by hand.`n")
        [void]$yaml.Append("`"*`":`n")
        foreach ($rule in $rules) {
            [void]$yaml.Append('  - "').Append($rule.Replace('\', '\\').Replace('"', '\"')).Append("`"`n")
        }
        if ($PSCmdlet.ShouldProcess($outFile, 'Write Content Exclusion YAML')) {
            [System.IO.File]::WriteAllText($outFile, $yaml.ToString(), $Utf8NoBom)
            Write-Host "Content Exclusion YAML: $outFile ($($rules.Count) rules)"
        }
    }

    # --- Resolve target repositories -------------------------------------------------------
    $targets = [System.Collections.Generic.List[string]]::new()
    foreach ($root in @($RootPath)) {
        if (-not $root) { continue }
        foreach ($repo in (Find-GitRepository (Resolve-Path -LiteralPath $root).ProviderPath)) { $targets.Add($repo) }
    }
    $targets.AddRange($pendingPaths)

    if ($targets.Count -eq 0) {
        if (-not $ContentExclusionOutFile) { Write-Warning 'Nothing to process. Use -RootPath, -RepositoryPath or pipeline input.' }
        return
    }

    # --- Apply, isolating failures per repository ------------------------------------------
    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $targets) {
        try {
            $repo = (Resolve-Path -LiteralPath $candidate).ProviderPath
            if (-not $seen.Add($repo)) { continue }
            Write-Verbose "Processing $repo"

            $plan   = Get-RepositoryPlan $repo
            $status = $plan.Status
            if ($plan.Mode) {
                if ($PSCmdlet.ShouldProcess($plan.Target, $plan.Operation)) {
                    Write-TextFile -Path $plan.Target -Text $plan.Text -Encoding $plan.Encoding -Mode $plan.Mode
                }
                else { $status = 'WhatIf' }
            }
            $results.Add([pscustomobject]@{
                Repository = $repo; Status = $status; Stacks = $plan.Stacks; RulesAdded = $plan.RulesAdded; Detail = $plan.Detail
            })
        }
        catch {
            Write-Warning "[$candidate] $($_.Exception.Message)"
            $results.Add([pscustomobject]@{
                Repository = $candidate; Status = 'Failed'; Stacks = ''; RulesAdded = 0; Detail = $_.Exception.Message
            })
        }
    }

    $results | Format-Table -AutoSize -Wrap Repository, Status, Stacks, RulesAdded, Detail | Out-String -Width 4096 | Write-Host
    $summary = ($results | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-Host "Summary: $summary"

    if ($PassThru) { $results }
    if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) { exit 1 }
}
