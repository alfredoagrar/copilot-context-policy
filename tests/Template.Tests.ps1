#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeDiscovery {
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
    $ExcludedPaths = @(Get-Content -LiteralPath (Join-Path $fixtures 'expected-excluded.txt') |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    $IncludedPaths = @(Get-Content -LiteralPath (Join-Path $fixtures 'expected-included.txt') |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}

BeforeAll {
    $RepoRoot     = Split-Path -Parent $PSScriptRoot
    $TemplatePath = Join-Path $RepoRoot 'templates/.copilotignore'
    $ScriptPath   = Join-Path $RepoRoot 'scripts/Set-CopilotIgnore.ps1'
    $Rules = @(Get-Content -LiteralPath $TemplatePath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })

    # git is the reference implementation of gitignore matching: run every fixture path
    # through "git check-ignore" once, using the template as the only exclude file.
    $sandbox = Join-Path $TestDrive 'git-sandbox'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    & git -C $sandbox init --quiet
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
    $paths = @(Get-Content -LiteralPath (Join-Path $fixtures 'expected-excluded.txt'), (Join-Path $fixtures 'expected-included.txt') |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    $excludesFile = $TemplatePath.Replace('\', '/')

    # Paths go as arguments, not --stdin: Windows pipes CRLF to native commands and git
    # would then match "path`r".
    $Matched = @{}
    & git -C $sandbox -c core.quotePath=false -c "core.excludesFile=$excludesFile" check-ignore --no-index --verbose --non-matching -- $paths |
        ForEach-Object {
            $source, $path = $_ -split "`t", 2
            $Matched[$path] = $source
        }
}

Describe 'templates/.copilotignore' {
    It 'declares a semantic @standard-version' {
        Get-Content -LiteralPath $TemplatePath -Raw | Should -Match '(?m)^#\s*@standard-version\s+\d+\.\d+\.\d+\s*$'
    }

    It 'only uses rules compatible with Content Exclusion (explicit anchor, no negation)' {
        @($Rules | Where-Object { $_.StartsWith('!') -or -not ($_.StartsWith('**/') -or $_.StartsWith('/')) }) |
            Should -BeNullOrEmpty
    }

    It 'has no duplicated rules' {
        @($Rules | Group-Object -CaseSensitive | Where-Object Count -gt 1) | Should -BeNullOrEmpty
    }

    Context 'pattern matching (git check-ignore)' {
        It 'excludes <_>' -ForEach $ExcludedPaths {
            $Matched.ContainsKey($_) | Should -BeTrue
            $Matched[$_] | Should -Not -Be '::' -Because 'this versioned file only burns tokens'
        }

        It 'keeps <_>' -ForEach $IncludedPaths {
            $Matched.ContainsKey($_) | Should -BeTrue
            $Matched[$_] | Should -Be '::' -Because "it is useful context for Copilot (matched by: $($Matched[$_]))"
        }
    }
}

Describe 'scripts/Set-CopilotIgnore.ps1 source' {
    It 'is ASCII-only (Windows PowerShell 5.1 reads BOM-less scripts as ANSI)' {
        $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}
