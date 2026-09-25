#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $RepoRoot      = Split-Path -Parent $PSScriptRoot
    $ScriptPath    = Join-Path $RepoRoot 'scripts/Set-CopilotIgnore.ps1'
    $TemplatePath  = Join-Path $RepoRoot 'templates/.copilotignore'
    $TemplateRules = @(Get-Content -LiteralPath $TemplatePath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
    $Utf8NoBom = New-Object System.Text.UTF8Encoding $false

    function New-TestRepository {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [switch] $DotNet,
            [switch] $NoGit
        )
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        if (-not $NoGit) { New-Item -ItemType Directory -Path (Join-Path $path '.git') -Force | Out-Null }
        if ($DotNet) { New-Item -ItemType File -Path (Join-Path $path 'src/App/App.csproj') -Force | Out-Null }
        return $path
    }
}

Describe 'Set-CopilotIgnore.ps1' {

    Context 'when .copilotignore does not exist' {
        It 'creates it from the template' {
            $repo = New-TestRepository -Name 'create' -DotNet

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status     | Should -Be 'Created'
            $result.RulesAdded | Should -Be $TemplateRules.Count
            $expected = ([System.IO.File]::ReadAllLines($TemplatePath) -join "`n") + "`n"
            [System.IO.File]::ReadAllText((Join-Path $repo '.copilotignore')) | Should -BeExactly $expected
        }

        It 'writes UTF-8 without BOM' {
            $repo = New-TestRepository -Name 'no-bom' -DotNet

            & $ScriptPath -RepositoryPath $repo 6>$null

            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo '.copilotignore'))
            $bytes[0] | Should -Be ([byte][char]'#')
        }

        It 'writes nothing with -WhatIf' {
            $repo = New-TestRepository -Name 'what-if' -DotNet

            $result = & $ScriptPath -RepositoryPath $repo -WhatIf -PassThru 6>$null

            $result.Status | Should -Be 'WhatIf'
            Join-Path $repo '.copilotignore' | Should -Not -Exist
        }
    }

    Context 'when .copilotignore already exists' {
        It 'appends only the missing rules and keeps the original content byte-for-byte' {
            $repo = New-TestRepository -Name 'append' -DotNet
            $file = Join-Path $repo '.copilotignore'
            $original = "# team rules`n/src/Legacy/big.json`n**/*.resx`n"
            [System.IO.File]::WriteAllText($file, $original, $Utf8NoBom)

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status     | Should -Be 'Updated'
            $result.RulesAdded | Should -Be ($TemplateRules.Count - 1)
            $content = [System.IO.File]::ReadAllText($file)
            $content.StartsWith($original) | Should -BeTrue
            @($content -split "`n" | Where-Object { $_ -eq '**/*.resx' }).Count | Should -Be 1
            $content | Should -Match '# >>> copilotignore-standard '
        }

        It 'is idempotent' {
            $repo = New-TestRepository -Name 'idempotent' -DotNet
            $file = Join-Path $repo '.copilotignore'
            [System.IO.File]::WriteAllText($file, "/custom.json`n", $Utf8NoBom)
            & $ScriptPath -RepositoryPath $repo 6>$null
            $hash = (Get-FileHash -LiteralPath $file).Hash

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status | Should -Be 'UpToDate'
            (Get-FileHash -LiteralPath $file).Hash | Should -Be $hash
        }

        It 'honors "# @disable <pattern>" opt-outs' {
            $repo = New-TestRepository -Name 'disable' -DotNet
            $file = Join-Path $repo '.copilotignore'
            [System.IO.File]::WriteAllText($file, "# @disable **/*.svg`n", $Utf8NoBom)

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.RulesAdded | Should -Be ($TemplateRules.Count - 1)
            @([System.IO.File]::ReadAllLines($file) | Where-Object { $_.Trim() -eq '**/*.svg' }).Count | Should -Be 0
        }

        It 'preserves CRLF line endings' {
            $repo = New-TestRepository -Name 'crlf' -DotNet
            $file = Join-Path $repo '.copilotignore'
            [System.IO.File]::WriteAllText($file, "/custom.json`r`n", $Utf8NoBom)

            & $ScriptPath -RepositoryPath $repo 6>$null

            [System.IO.File]::ReadAllText($file).Replace("`r`n", '') | Should -Not -Match "`n"
        }

        It 'preserves UTF-16 LE encoding and the original bytes' {
            $repo = New-TestRepository -Name 'utf16' -DotNet
            $file = Join-Path $repo '.copilotignore'
            $unicode = [System.Text.Encoding]::Unicode
            [System.IO.File]::WriteAllText($file, "/custom.json`r`n", $unicode)
            $before = [System.IO.File]::ReadAllBytes($file)

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status | Should -Be 'Updated'
            $after = [System.IO.File]::ReadAllBytes($file)
            [Convert]::ToBase64String($after, 0, $before.Length) | Should -Be ([Convert]::ToBase64String($before))
            [System.IO.File]::ReadAllText($file, $unicode) | Should -Match ([regex]::Escape('**/*.resx'))
        }
    }

    Context 'repository selection' {
        It 'skips repositories without .NET projects' {
            $repo = New-TestRepository -Name 'node-only'
            New-Item -ItemType File -Path (Join-Path $repo 'package.json') | Out-Null

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status | Should -Be 'Skipped'
            Join-Path $repo '.copilotignore' | Should -Not -Exist
        }

        It 'ignores project files under bin, obj and node_modules' {
            $repo = New-TestRepository -Name 'vendored'
            New-Item -ItemType File -Path (Join-Path $repo 'node_modules/pkg/Sample.csproj') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $repo 'obj/Debug/Sample.csproj') -Force | Out-Null

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status | Should -Be 'Skipped'
        }

        It 'skips folders that are not a Git repository root' {
            $dir = New-TestRepository -Name 'no-git' -DotNet -NoGit

            $result = & $ScriptPath -RepositoryPath $dir -PassThru 6>$null

            $result.Status | Should -Be 'Skipped'
            Join-Path $dir '.copilotignore' | Should -Not -Exist
        }

        It 'discovers repositories under -RootPath without descending into them' {
            $repoA  = New-TestRepository -Name 'root/team-a/svc-a' -DotNet
            $repoB  = New-TestRepository -Name 'root/svc-b' -DotNet
            $nested = New-TestRepository -Name 'root/svc-b/vendor/inner' -DotNet
            $deep   = New-TestRepository -Name 'root/x/y/z/too-deep' -DotNet

            $results = @(& $ScriptPath -RootPath (Join-Path $TestDrive 'root') -PassThru 6>$null)

            $results.Count | Should -Be 2
            Join-Path $repoA '.copilotignore'  | Should -Exist
            Join-Path $repoB '.copilotignore'  | Should -Exist
            Join-Path $nested '.copilotignore' | Should -Not -Exist
            Join-Path $deep '.copilotignore'   | Should -Not -Exist
        }

        It 'accepts pipeline input and ignores blank lines and comments' {
            $repo = New-TestRepository -Name 'piped' -DotNet

            $results = @(@('# repos.txt', '', $repo, '   ') | & $ScriptPath -PassThru 6>$null)

            $results.Count     | Should -Be 1
            $results[0].Status | Should -Be 'Created'
        }
    }

    Context 'error handling' {
        It 'isolates failures per repository and exits with code 1' {
            $ok      = New-TestRepository -Name 'isolation-ok' -DotNet
            $missing = Join-Path $TestDrive 'does-not-exist'

            $results = @(& $ScriptPath -RepositoryPath $missing, $ok -PassThru 6>$null 3>$null)

            $LASTEXITCODE | Should -Be 1
            @($results | Where-Object Status -eq 'Failed')[0].Repository | Should -Be $missing
            @($results | Where-Object Status -eq 'Created').Count | Should -Be 1
        }
    }

    Context 'Content Exclusion export' {
        It 'writes the organization-level YAML with every template rule' {
            $out = Join-Path $TestDrive 'content-exclusion.org.yml'

            & $ScriptPath -ContentExclusionOutFile $out 6>$null

            $lines = @(Get-Content -LiteralPath $out)
            $lines | Should -Contain '"*":'
            @($lines | Where-Object { $_.StartsWith('  - "') }).Count | Should -Be $TemplateRules.Count
        }
    }
}
