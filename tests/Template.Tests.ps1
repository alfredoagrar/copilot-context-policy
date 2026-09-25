#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../templates/profiles.json') -Raw | ConvertFrom-Json
    $ProfileCases = @($manifest.profiles | ForEach-Object { @{ Name = $_.name; Template = $_.template } })

    function Read-Fixture([string] $Path) {
        @(Get-Content -LiteralPath $Path | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    $ExcludedCases = @(); $IncludedCases = @()
    foreach ($name in @($manifest.profiles | ForEach-Object { $_.name })) {
        $dir = Join-Path $PSScriptRoot "fixtures/$name"
        $ExcludedCases += @(Read-Fixture (Join-Path $dir 'excluded.txt') | ForEach-Object { @{ Stack = $name; Path = $_ } })
        $IncludedCases += @(Read-Fixture (Join-Path $dir 'included.txt') | ForEach-Object { @{ Stack = $name; Path = $_ } })
    }
}

BeforeAll {
    $RepoRoot    = Split-Path -Parent $PSScriptRoot
    $TemplateDir = Join-Path $RepoRoot 'templates'
    $ScriptPath  = Join-Path $RepoRoot 'scripts/Set-CopilotIgnore.ps1'
    $Manifest    = Get-Content -LiteralPath (Join-Path $TemplateDir 'profiles.json') -Raw | ConvertFrom-Json

    function Get-Rule([string] $Path) {
        @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    function Read-Fixture([string] $Path) {
        @(Get-Content -LiteralPath $Path | Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    $RulesByProfile = @{}
    foreach ($entry in $Manifest.profiles) { $RulesByProfile[$entry.name] = Get-Rule (Join-Path $TemplateDir $entry.template) }

    # git is the reference implementation of gitignore matching. core.ignoreCase=true emulates
    # Content Exclusion, which matches case-insensitively.
    $sandbox = Join-Path $TestDrive 'git-sandbox'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    & git -C $sandbox init --quiet

    function Invoke-CheckIgnore([string[]] $Rules, [string[]] $Paths, [switch] $IgnoreCase) {
        $excludes = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.ignore')
        [System.IO.File]::WriteAllText($excludes, ($Rules -join "`n") + "`n")
        $gitArgs = @('-C', $sandbox, '-c', 'core.quotePath=false', '-c', "core.excludesFile=$($excludes.Replace('\', '/'))")
        if ($IgnoreCase) { $gitArgs += @('-c', 'core.ignoreCase=true') }
        # Paths go as arguments, not --stdin: Windows pipes CRLF to native commands.
        $matched = @{}
        & git @gitArgs check-ignore --no-index --verbose --non-matching -- $Paths | ForEach-Object {
            $source, $path = $_ -split "`t", 2
            $matched[$path] = $source
        }
        $matched
    }

    # Excluded paths: checked against common + their own profile (what a repository receives).
    $ExcludedResult = @{}
    foreach ($entry in $Manifest.profiles) {
        $rules = @($RulesByProfile['common'])
        if ($entry.name -ne 'common') { $rules += $RulesByProfile[$entry.name] }
        $paths = Read-Fixture (Join-Path $PSScriptRoot "fixtures/$($entry.name)/excluded.txt")
        $ExcludedResult[$entry.name] = Invoke-CheckIgnore -Rules $rules -Paths $paths
    }

    # Included paths: checked against the union of every profile, case-insensitively (what the
    # organization-level Content Exclusion applies to every repository).
    $allRules = @($Manifest.profiles | ForEach-Object { $RulesByProfile[$_.name] })
    $allIncluded = @($Manifest.profiles | ForEach-Object { Read-Fixture (Join-Path $PSScriptRoot "fixtures/$($_.name)/included.txt") })
    $UnionResult = Invoke-CheckIgnore -Rules $allRules -Paths $allIncluded -IgnoreCase
}

Describe 'templates/profiles.json' {
    It 'declares a semantic version' {
        $Manifest.version | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'has exactly one always-on profile, named common' {
        @($Manifest.profiles | Where-Object { $_.always } | ForEach-Object { $_.name }) | Should -Be @('common')
    }

    It 'gives every other profile at least one marker' {
        @($Manifest.profiles | Where-Object { -not $_.always -and @($_.markers).Count -eq 0 }) | Should -BeNullOrEmpty
    }
}

Describe 'template <Template>' -ForEach $ProfileCases {
    It 'exists, starts with a comment-only header block and has rules' {
        $path = Join-Path $TemplateDir $Template
        $path | Should -Exist
        (Get-Content -LiteralPath $path -TotalCount 1) | Should -Match '^#'
        $RulesByProfile[$Name].Count | Should -BeGreaterThan 0
    }

    It 'only uses rules compatible with Content Exclusion (explicit anchor, no negation)' {
        @($RulesByProfile[$Name] | Where-Object { $_.StartsWith('!') -or -not ($_.StartsWith('**/') -or $_.StartsWith('/')) }) |
            Should -BeNullOrEmpty
    }
}

Describe 'rule set' {
    It 'never repeats a rule, within or across templates' {
        $all = @($Manifest.profiles | ForEach-Object { $RulesByProfile[$_.name] })
        @($all | Group-Object -CaseSensitive | Where-Object Count -gt 1 | ForEach-Object { $_.Name }) | Should -BeNullOrEmpty
    }

    It 'keeps every v1.0.0 rule in common or dotnet (append-only upgrades never lose rules)' {
        $v1 = Get-Rule (Join-Path $PSScriptRoot 'fixtures/v1.0.0.copilotignore')
        $v2 = @($RulesByProfile['common']) + @($RulesByProfile['dotnet'])
        @($v1 | Where-Object { $v2 -cnotcontains $_ }) | Should -BeNullOrEmpty
    }

    Context 'pattern matching (git check-ignore)' {
        It '[<Stack>] excludes <Path>' -ForEach $ExcludedCases {
            $ExcludedResult[$Stack].ContainsKey($Path) | Should -BeTrue
            $ExcludedResult[$Stack][$Path] | Should -Not -Be '::' -Because 'this versioned file only burns tokens'
        }

        It '[<Stack>] keeps <Path> under the case-insensitive union of all profiles' -ForEach $IncludedCases {
            $UnionResult.ContainsKey($Path) | Should -BeTrue
            $UnionResult[$Path] | Should -Be '::' -Because "it is useful context (matched by: $($UnionResult[$Path]))"
        }
    }
}

Describe 'scripts/Set-CopilotIgnore.ps1 source' {
    It 'is ASCII-only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI)' {
        $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
