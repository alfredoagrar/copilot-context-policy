# copilot-context-policy

[![ci](https://github.com/alfredoagrar/copilot-context-policy/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/alfredoagrar/copilot-context-policy/actions/workflows/ci.yml)

A versioned standard that keeps GitHub Copilot from spending tokens on **versioned files that add no value as context** in .NET / C# repositories: resource files, generated code, EF Core migrations, seed data and heavy documentation. It also includes the tooling to roll it out and enforce it across an organization.

## Why

- Since June 1, 2026, Copilot bills by token consumption (GitHub AI Credits). Large generated or data files that end up in the context window cost money and add noise to suggestions.
- `.gitignore` does not help, because these files *are* committed.
- GitHub does **not** document `.copilotignore` as a natively enforced file. The official control is [Copilot Content Exclusion](https://docs.github.com/en/copilot/how-tos/configure-content-exclusion/exclude-content-from-copilot) (repository, organization or enterprise settings; Copilot Business/Enterprise).

This repository treats `templates/.copilotignore` as the **single source of truth**. Every repository gets a copy, and the organization-level Content Exclusion YAML is generated from the same template.

## Contents

| Path | Purpose |
|---|---|
| [`templates/.copilotignore`](templates/.copilotignore) | The standard: 63 rules in 5 sections plus a section for repository-specific rules. |
| [`scripts/Set-CopilotIgnore.ps1`](scripts/Set-CopilotIgnore.ps1) | Rollout script: injects or updates the file in every .NET repository, append-only. |
| [`.github/workflows/copilotignore-check.yml`](.github/workflows/copilotignore-check.yml) | Reusable GitHub Actions workflow that fails PRs without a valid `.copilotignore`. |
| [`pipelines/github/copilotignore.yml`](pipelines/github/copilotignore.yml) | Consumer workflow that calls the reusable workflow. |
| [`pipelines/azure/validate-copilotignore.steps.yml`](pipelines/azure/validate-copilotignore.steps.yml) | Same check as an Azure Pipelines step template. |
| [`pipelines/azure/azure-pipelines.example.yml`](pipelines/azure/azure-pipelines.example.yml) | Consumer pipeline for Azure Repos. |
| [`tests/`](tests) | Pester tests for the script plus pattern tests that use `git check-ignore` as the matching oracle. |

## What gets excluded

| Section | Examples | Kept on purpose |
|---|---|---|
| 1. Resources and translations | `*.resx`, `*.xlf`, `locales/**`, `i18n/**/*.json` | – |
| 2. Generated code | `swagger*.json`, `*.g.cs`, `Generated/**`, `Connected Services/**`, `*.Designer.cs`, `*.edmx`, `CompiledModels/**`, lock files, `wwwroot/lib/**`, `*.min.js` | – |
| 3. EF migrations | `**/[Mm]igrations/**` | `DbContext`, `IEntityTypeConfiguration<T>` |
| 4. Seed data and data-load scripts | `*.csv`, `*.jsonl`, `Seed*/**/*.json`, `TestData/**/*.json`, `*seed*.sql`, `PostDeploy*/**/*.sql` | Seeder and fixture **`.cs`** code, schema and stored-procedure `.sql` |
| 5. Heavy docs and diagrams | `*.pdf`, `*.svg`, `*.drawio`, `*.puml`, `docs/**/*.html`, `_site/**` | Markdown (README, ADRs) |

Rules use the subset of syntax that both gitignore and Content Exclusion (fnmatch) understand: an explicit `**/` or `/` anchor and no `!` negations. CI enforces this.

## Quick start

### 1. Roll out `.copilotignore`

```powershell
# Preview: nothing is written
./scripts/Set-CopilotIgnore.ps1 -RootPath C:\src -WhatIf

# Apply to every .NET repository under C:\src (up to 2 levels deep)
./scripts/Set-CopilotIgnore.ps1 -RootPath C:\src

# Or from an explicit list; blank lines and '#' comments are ignored
Get-Content .\repos.txt | ./scripts/Set-CopilotIgnore.ps1 -PassThru | Export-Csv .\rollout.csv -NoTypeInformation
```

The script leaves changes uncommitted, so each team reviews and commits the file through its normal PR flow.

### 2. Apply the official Content Exclusion

```powershell
./scripts/Set-CopilotIgnore.ps1 -ContentExclusionOutFile .\content-exclusion.org.yml
```

Paste the output into **Organization settings > Copilot > Content exclusion**. Each release also attaches this YAML as an asset.

### 3. Enforce it on pull requests

**GitHub Actions**: add [`pipelines/github/copilotignore.yml`](pipelines/github/copilotignore.yml) to each repository, or require it for the whole organization with *Rulesets > Require workflows to pass before merging*:

```yaml
jobs:
  copilotignore:
    uses: alfredoagrar/copilot-context-policy/.github/workflows/copilotignore-check.yml@v1
```

**Azure Pipelines**: reference the step template from this repository (see [`azure-pipelines.example.yml`](pipelines/azure/azure-pipelines.example.yml)) and register the pipeline as a *Build validation* branch policy. Azure Repos ignores the YAML `pr:` trigger.

## How the script behaves

- **Never overwrites.** A new file is created with `FileMode.CreateNew`. If the file already exists, only the missing rules are appended, between `# >>> copilotignore-standard <version> >>>` markers. Running it again changes nothing.
- **Preserves the existing file.** Encoding (UTF-8 with or without BOM, UTF-16) and line endings (CRLF/LF) are kept as they are.
- **Targets .NET only.** A repository is processed only if it contains `*.sln`, `*.slnx`, `*.csproj`, `*.fsproj` or `*.vbproj`. `bin/`, `obj/` and `node_modules/` are not searched.
- **Isolates failures.** A failing repository does not stop the others. The script ends with a summary table and exits with code 1 if any repository failed.
- **Runs anywhere.** Windows PowerShell 5.1 and PowerShell 7+ on Windows, Linux and macOS. The file is ASCII-only on purpose.

### Opting out of a rule

Delete the rule from the repository's `.copilotignore` and add a marker so the script does not append it again:

```gitignore
# @disable **/*.svg
```

The marker only affects that repository's `.copilotignore`. An organization-level Content Exclusion still applies to every repository.

## Known limitations

- Content Exclusion does not apply to **Agent mode in Copilot Chat in IDEs**. The Copilot app and Copilot CLI honor it since September 2, 2026.
- Rollout is append-only: **removing** a rule from the template does not remove it from repositories that already have it. That is why removals are major versions (see [CONTRIBUTING.md](CONTRIBUTING.md#versioning)).
- Globs cannot express "large file". Add root-anchored paths for outliers in section `[6]` of each repository's file.

## Versioning

Releases follow SemVer and are cut from `main` with a `vX.Y.Z` tag that must match `@standard-version` in the template. The release workflow publishes the assets and moves the major tag (`v1`), which is the reference consumers should pin to.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). To propose a new rule, open a [rule proposal](https://github.com/alfredoagrar/copilot-context-policy/issues/new?template=rule-proposal.yml).

## License

[MIT](LICENSE)
