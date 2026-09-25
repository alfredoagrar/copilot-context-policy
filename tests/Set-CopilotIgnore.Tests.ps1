#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $RepoRoot    = Split-Path -Parent $PSScriptRoot
    $ScriptPath  = Join-Path $RepoRoot 'scripts/Set-CopilotIgnore.ps1'
    $TemplateDir = Join-Path $RepoRoot 'templates'
    $Manifest    = Get-Content -LiteralPath (Join-Path $TemplateDir 'profiles.json') -Raw | ConvertFrom-Json
    $V1Template  = Join-Path $PSScriptRoot 'fixtures/v1.0.0.copilotignore'
    $Utf8NoBom   = New-Object System.Text.UTF8Encoding $false

    function Get-TemplateRule([string] $Name) {
        $entry = @($Manifest.profiles | Where-Object { $_.name -eq $Name })[0]
        @(Get-Content -LiteralPath (Join-Path $TemplateDir $entry.template) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    function Get-ExpectedRuleCount([string[]] $Stacks) {
        # Templates never share rules (see Template.Tests.ps1), so counts can be added up.
        $count = 0
        foreach ($name in @('common') + $Stacks) { $count += (Get-TemplateRule $name).Count }
        $count
    }

    function New-TestRepository {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [string[]] $Files = @(),
            [switch] $NoGit
        )
        $path = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        if (-not $NoGit) { New-Item -ItemType Directory -Path (Join-Path $path '.git') -Force | Out-Null }
        foreach ($file in $Files) { New-Item -ItemType File -Path (Join-Path $path $file) -Force | Out-Null }
        return $path
    }
}

Describe 'Set-CopilotIgnore.ps1' {

    Context 'stack detection' {
        It 'composes common + dotnet for a .NET repository' {
            $repo = New-TestRepository -Name 'dotnet' -Files 'src/App/App.csproj'

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status     | Should -Be 'Created'
            $result.Stacks     | Should -Be 'common,dotnet'
            $result.RulesAdded | Should -Be (Get-ExpectedRuleCount 'dotnet')
            $lines = [System.IO.File]::ReadAllLines((Join-Path $repo '.copilotignore'))
            $lines | Should -Contain '#  Stacks: common, dotnet'
            $lines | Should -Contain '**/*.resx'
            $lines | Should -Not -Contain '**/__snapshots__/**'
        }

        It 'detects several stacks in one repository' {
            $repo = New-TestRepository -Name 'fullstack' -Files 'Portal.sln', 'src/Web/ClientApp/package.json'

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Stacks     | Should -Be 'common,dotnet,node'
            $result.RulesAdded | Should -Be (Get-ExpectedRuleCount 'dotnet', 'node')
        }

        It 'detects <Stack> from <Marker>' -ForEach @(
            @{ Stack = 'node'; Marker = 'package.json' }
            @{ Stack = 'python'; Marker = 'pyproject.toml' }
            @{ Stack = 'python'; Marker = 'requirements.txt' }
            @{ Stack = 'java'; Marker = 'pom.xml' }
            @{ Stack = 'java'; Marker = 'build.gradle.kts' }
            @{ Stack = 'go'; Marker = 'go.mod' }
        ) {
            $repo = New-TestRepository -Name "detect-$Stack-$Marker" -Files $Marker

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Stacks | Should -Be "common,$Stack"
        }

        It 'applies only the common profile when no stack is detected' {
            $repo = New-TestRepository -Name 'docs-only' -Files 'README.md'

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status     | Should -Be 'Created'
            $result.Stacks     | Should -Be 'common'
            $result.RulesAdded | Should -Be (Get-ExpectedRuleCount @())
        }

        It 'ignores markers under bin, obj and node_modules' {
            $repo = New-TestRepository -Name 'vendored' -Files 'node_modules/pkg/package.json', 'obj/Debug/Sample.csproj'

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Stacks | Should -Be 'common'
        }

        It 'uses -Stack instead of detection' {
            $repo = New-TestRepository -Name 'forced' -Files 'src/App/App.csproj'

            $result = & $ScriptPath -RepositoryPath $repo -Stack python -PassThru 6>$null

            $result.Stacks | Should -Be 'common,python'
        }

        It 'rejects an unknown -Stack' {
            $repo = New-TestRepository -Name 'unknown-stack' -Files 'src/App/App.csproj'

            { & $ScriptPath -RepositoryPath $repo -Stack cobol 6>$null } | Should -Throw '*Unknown stack*'
        }
    }

    Context 'when .copilotignore does not exist' {
        It 'writes UTF-8 without BOM' {
            $repo = New-TestRepository -Name 'no-bom' -Files 'src/App/App.csproj'

            & $ScriptPath -RepositoryPath $repo 6>$null

            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $repo '.copilotignore'))
            $bytes[0] | Should -Be ([byte][char]'#')
        }

        It 'writes nothing with -WhatIf' {
            $repo = New-TestRepository -Name 'what-if' -Files 'src/App/App.csproj'

            $result = & $ScriptPath -RepositoryPath $repo -WhatIf -PassThru 6>$null

            $result.Status | Should -Be 'WhatIf'
            Join-Path $repo '.copilotignore' | Should -Not -Exist
        }
    }

    Context 'when .copilotignore already exists' {
        It 'appends only the missing rules and keeps the original content byte-for-byte' {
            $repo = New-TestRepository -Name 'append' -Files 'src/App/App.csproj'
            $file = Join-Path $repo '.copilotignore'
            $original = "# team rules`n/src/Legacy/big.json`n**/*.resx`n"
            [System.IO.File]::WriteAllText($file, $original, $Utf8NoBom)

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status     | Should -Be 'Updated'
            $result.RulesAdded | Should -Be ((Get-ExpectedRuleCount 'dotnet') - 1)
            $content = [System.IO.File]::ReadAllText($file)
            $content.StartsWith($original) | Should -BeTrue
            @($content -split "`n" | Where-Object { $_ -eq '**/*.resx' }).Count | Should -Be 1
            $content | Should -Match '# >>> copilot-context-policy \S+ \[common,dotnet\]'
        }

        It 'upgrades a v1.0.0 file by appending only the rules v1 did not have' {
            $repo = New-TestRepository -Name 'upgrade-v1' -Files 'src/App/App.csproj', 'web/package.json'
            $file = Join-Path $repo '.copilotignore'
            Copy-Item -LiteralPath $V1Template -Destination $file
            $v1Rules  = @(Get-Content -LiteralPath $V1Template | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
            $original = [System.IO.File]::ReadAllText($file)

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status     | Should -Be 'Updated'
            $result.RulesAdded | Should -Be ((Get-ExpectedRuleCount 'dotnet', 'node') - $v1Rules.Count)
            $content = [System.IO.File]::ReadAllText($file)
            $content.StartsWith($original) | Should -BeTrue
            $rules = @($content -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
            @($rules | Group-Object -CaseSensitive | Where-Object Count -gt 1) | Should -BeNullOrEmpty
        }

        It 'is idempotent' {
            $repo = New-TestRepository -Name 'idempotent' -Files 'src/App/App.csproj'
            $file = Join-Path $repo '.copilotignore'
            [System.IO.File]::WriteAllText($file, "/custom.json`n", $Utf8NoBom)
            & $ScriptPath -RepositoryPath $repo 6>$null
            $hash = (Get-FileHash -LiteralPath $file).Hash

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.Status | Should -Be 'UpToDate'
            (Get-FileHash -LiteralPath $file).Hash | Should -Be $hash
        }

        It 'honors "# @disable <pattern>" opt-outs' {
            $repo = New-TestRepository -Name 'disable' -Files 'src/App/App.csproj'
            $file = Join-Path $repo '.copilotignore'
            [System.IO.File]::WriteAllText($file, "# @disable **/*.svg`n", $Utf8NoBom)

            $result = & $ScriptPath -RepositoryPath $repo -PassThru 6>$null

            $result.RulesAdded | Should -Be ((Get-ExpectedRuleCount 'dotnet') - 1)
            @([System.IO.File]::ReadAllLines($file) | Where-Object { $_.Trim() -eq '**/*.svg' }).Count | Should -Be 0
        }

        It 'preserves CRLF line endings' {
            $repo = New-TestRepository -Name 'crlf' -Files 'src/App/App.csproj'
            $file = Join-Path $repo '.copilotignore'
            [System.IO.File]::WriteAllText($file, "/custom.json`r`n", $Utf8NoBom)

            & $ScriptPath -RepositoryPath $repo 6>$null

            [System.IO.File]::ReadAllText($file).Replace("`r`n", '') | Should -Not -Match "`n"
        }

        It 'preserves UTF-16 LE encoding and the original bytes' {
            $repo = New-TestRepository -Name 'utf16' -Files 'src/App/App.csproj'
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
        It 'skips folders that are not a Git repository root' {
            $dir = New-TestRepository -Name 'no-git' -Files 'src/App/App.csproj' -NoGit

            $result = & $ScriptPath -RepositoryPath $dir -PassThru 6>$null

            $result.Status | Should -Be 'Skipped'
            Join-Path $dir '.copilotignore' | Should -Not -Exist
        }

        It 'discovers repositories under -RootPath without descending into them' {
            $repoA  = New-TestRepository -Name 'root/team-a/svc-a' -Files 'src/App/App.csproj'
            $repoB  = New-TestRepository -Name 'root/svc-b' -Files 'go.mod'
            $nested = New-TestRepository -Name 'root/svc-b/vendor/inner' -Files 'go.mod'
            $deep   = New-TestRepository -Name 'root/x/y/z/too-deep' -Files 'go.mod'

            $results = @(& $ScriptPath -RootPath (Join-Path $TestDrive 'root') -PassThru 6>$null)

            $results.Count | Should -Be 2
            Join-Path $repoA '.copilotignore'  | Should -Exist
            Join-Path $repoB '.copilotignore'  | Should -Exist
            Join-Path $nested '.copilotignore' | Should -Not -Exist
            Join-Path $deep '.copilotignore'   | Should -Not -Exist
        }

        It 'accepts pipeline input and ignores blank lines and comments' {
            $repo = New-TestRepository -Name 'piped' -Files 'src/App/App.csproj'

            $results = @(@('# repos.txt', '', $repo, '   ') | & $ScriptPath -PassThru 6>$null)

            $results.Count     | Should -Be 1
            $results[0].Status | Should -Be 'Created'
        }
    }

    Context 'error handling' {
        It 'isolates failures per repository and exits with code 1' {
            $ok      = New-TestRepository -Name 'isolation-ok' -Files 'src/App/App.csproj'
            $missing = Join-Path $TestDrive 'does-not-exist'

            $results = @(& $ScriptPath -RepositoryPath $missing, $ok -PassThru 6>$null 3>$null)

            $LASTEXITCODE | Should -Be 1
            @($results | Where-Object Status -eq 'Failed')[0].Repository | Should -Be $missing
            @($results | Where-Object Status -eq 'Created').Count | Should -Be 1
        }
    }

    Context 'Content Exclusion export' {
        It 'writes the union of every profile by default' {
            $out = Join-Path $TestDrive 'content-exclusion.all.yml'

            & $ScriptPath -ContentExclusionOutFile $out 6>$null

            $lines = @(Get-Content -LiteralPath $out)
            $lines | Should -Contain '"*":'
            $allStacks = @($Manifest.profiles | Where-Object { -not $_.always } | ForEach-Object { $_.name })
            @($lines | Where-Object { $_.StartsWith('  - "') }).Count | Should -Be (Get-ExpectedRuleCount $allStacks)
        }

        It 'restricts the export to -Stack' {
            $out = Join-Path $TestDrive 'content-exclusion.dotnet.yml'

            & $ScriptPath -ContentExclusionOutFile $out -Stack dotnet 6>$null

            @(Get-Content -LiteralPath $out | Where-Object { $_.StartsWith('  - "') }).Count | Should -Be (Get-ExpectedRuleCount 'dotnet')
        }
    }
}
