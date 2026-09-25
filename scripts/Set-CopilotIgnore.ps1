#Requires -Version 5.1
<#
.SYNOPSIS
    Injects or updates the corporate .copilotignore standard in .NET repositories.

.DESCRIPTION
    - Discovers Git repositories under -RootPath and/or takes explicit roots (-RepositoryPath or pipeline).
    - Only processes the root of .NET repositories (*.sln, *.slnx, *.csproj, *.fsproj, *.vbproj).
    - Missing file: created from the template with FileMode.CreateNew (never replaces an existing file).
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

.PARAMETER TemplatePath
    Template to apply. Defaults to ../templates/.copilotignore relative to this script.

.PARAMETER DiscoveryDepth
    Maximum folder depth below -RootPath where repositories are searched for.

.PARAMETER ProjectSearchDepth
    Maximum folder depth inside a repository where .NET project files are searched for.

.PARAMETER ContentExclusionOutFile
    Also writes the organization-level GitHub Copilot Content Exclusion YAML generated from the template.

.PARAMETER PassThru
    Emits one result object per repository.

.EXAMPLE
    ./Set-CopilotIgnore.ps1 -RootPath C:\src -WhatIf

.EXAMPLE
    Get-Content .\repos.txt | ./Set-CopilotIgnore.ps1 -PassThru | Export-Csv .\rollout.csv -NoTypeInformation

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

    [string] $TemplatePath,

    [ValidateRange(0, 10)]
    [int] $DiscoveryDepth = 2,

    [ValidateRange(0, 10)]
    [int] $ProjectSearchDepth = 4,

    [string] $ContentExclusionOutFile,

    [switch] $PassThru
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $FileName  = '.copilotignore'
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $ProjectExtensions = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('.sln', '.slnx', '.csproj', '.fsproj', '.vbproj'),
        [System.StringComparer]::OrdinalIgnoreCase)
    $SkipDirs = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@('.git', '.vs', '.idea', 'bin', 'obj', 'node_modules', 'packages', 'TestResults', 'artifacts'),
        [System.StringComparer]::OrdinalIgnoreCase)
    Write-Verbose "Discovery depth: $DiscoveryDepth; project search depth: $ProjectSearchDepth"

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

    function Test-DotNetRepository([string] $Path) {
        # Depth-bounded BFS that stops at the first project file.
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(@($Path, 0))
        while ($queue.Count -gt 0) {
            $dir, $depth = $queue.Dequeue()
            try {
                foreach ($file in [System.IO.Directory]::EnumerateFiles($dir)) {
                    if ($ProjectExtensions.Contains([System.IO.Path]::GetExtension($file))) { return $true }
                }
            }
            catch { Write-Verbose "Skipping '$dir': $($_.Exception.Message)" }
            if ($depth -lt $ProjectSearchDepth) {
                foreach ($sub in (Get-ChildDirectory $dir)) { $queue.Enqueue(@($sub, ($depth + 1))) }
            }
        }
        return $false
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

    function Get-MissingBlock([System.Collections.Generic.HashSet[string]] $ExistingRules) {
        # Walks the template block by block (blocks are separated by blank lines) and keeps a
        # block's comments only when at least one of its rules is missing.
        $lines = [System.Collections.Generic.List[string]]::new()
        $added = 0
        foreach ($block in $TemplateBlocks) {
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
        if ($lines.Count -gt 0) { $lines.RemoveAt($lines.Count - 1) }
        return [pscustomobject]@{ Lines = $lines.ToArray(); Count = $added }
    }

    function Get-RepositoryPlan([string] $Path) {
        # Decides what to do with a repository without touching the disk.
        $plan = [pscustomobject]@{
            Status = ''; Target = $null; Mode = $null; Text = $null; Encoding = $null
            Operation = $null; RulesAdded = 0; Detail = "Standard $StandardVersion"
        }

        if (-not (Test-GitRoot $Path)) {
            $plan.Status = 'Skipped'; $plan.Detail = 'Not a Git repository root'
            return $plan
        }
        if (-not (Test-DotNetRepository $Path)) {
            $plan.Status = 'Skipped'; $plan.Detail = 'No .NET projects found'
            return $plan
        }

        $plan.Target = [System.IO.Path]::Combine($Path, $FileName)
        if ([System.IO.Directory]::Exists($plan.Target)) { throw "'$($plan.Target)' is a directory." }

        if (-not [System.IO.File]::Exists($plan.Target)) {
            $plan.Status = 'Created'; $plan.Mode = 'CreateNew'; $plan.Operation = 'Create from template'
            $plan.Text = $TemplateText; $plan.Encoding = $Utf8NoBom; $plan.RulesAdded = $TemplateRules.Count
            return $plan
        }

        $existing = Read-TextFile $plan.Target
        $missing  = Get-MissingBlock (ConvertTo-RuleSet $existing.Text)
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
        [void]$sb.Append("# >>> copilotignore-standard $StandardVersion | $(Get-Date -Format 'yyyy-MM-dd') | appended by Set-CopilotIgnore.ps1 >>>").Append($eol)
        foreach ($line in $missing.Lines) { [void]$sb.Append($line).Append($eol) }
        [void]$sb.Append('# <<< copilotignore-standard <<<').Append($eol)

        $plan.Status = 'Updated'; $plan.Mode = 'Append'; $plan.Operation = "Append $($missing.Count) missing rule(s)"
        $plan.Text = $sb.ToString(); $plan.Encoding = $existing.Encoding; $plan.RulesAdded = $missing.Count
        return $plan
    }

    # --- Load and validate the template ----------------------------------------------------
    if (-not $TemplatePath) {
        if (-not $PSScriptRoot) { throw 'Cannot resolve the script location; pass -TemplatePath.' }
        $TemplatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates/.copilotignore'
    }
    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw "Template not found: $TemplatePath" }

    $templateFile  = (Resolve-Path -LiteralPath $TemplatePath).ProviderPath
    $templateLines = [System.IO.File]::ReadAllLines($templateFile, $Utf8NoBom)
    $TemplateText  = ($templateLines -join "`n") + "`n"
    $TemplateRules = @($templateLines | Where-Object { Test-IsRule $_ } | ForEach-Object { $_.Trim() })
    if ($TemplateRules.Count -eq 0) { throw "Template '$templateFile' contains no rules." }

    $StandardVersion = 'unversioned'
    foreach ($line in $templateLines) {
        if ($line -match '^\s*#\s*@standard-version\s+(\S+)') { $StandardVersion = $Matches[1]; break }
    }

    $TemplateBlocks = [System.Collections.Generic.List[object]]::new()
    $current = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $templateLines) {
        if ($line.Trim().Length -eq 0) {
            if ($current.Count -gt 0) { $TemplateBlocks.Add($current.ToArray()); $current.Clear() }
        }
        else { $current.Add($line) }
    }
    if ($current.Count -gt 0) { $TemplateBlocks.Add($current.ToArray()) }

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
        $outFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ContentExclusionOutFile)
        $yaml = [System.Text.StringBuilder]::new()
        [void]$yaml.Append("# GitHub Copilot > Content exclusion (organization level). Standard $StandardVersion.`n")
        [void]$yaml.Append("# Generated by Set-CopilotIgnore.ps1 from the $FileName template. Do not edit by hand.`n")
        [void]$yaml.Append("`"*`":`n")
        foreach ($rule in $TemplateRules) {
            [void]$yaml.Append('  - "').Append($rule.Replace('\', '\\').Replace('"', '\"')).Append("`"`n")
        }
        if ($PSCmdlet.ShouldProcess($outFile, 'Write Content Exclusion YAML')) {
            [System.IO.File]::WriteAllText($outFile, $yaml.ToString(), $Utf8NoBom)
            Write-Host "Content Exclusion YAML: $outFile ($($TemplateRules.Count) rules)"
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
            $results.Add([pscustomobject]@{ Repository = $repo; Status = $status; RulesAdded = $plan.RulesAdded; Detail = $plan.Detail })
        }
        catch {
            Write-Warning "[$candidate] $($_.Exception.Message)"
            $results.Add([pscustomobject]@{ Repository = $candidate; Status = 'Failed'; RulesAdded = 0; Detail = $_.Exception.Message })
        }
    }

    $results | Format-Table -AutoSize -Wrap Repository, Status, RulesAdded, Detail | Out-String -Width 4096 | Write-Host
    $summary = ($results | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-Host "Summary: $summary"

    if ($PassThru) { $results }
    if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) { exit 1 }
}
