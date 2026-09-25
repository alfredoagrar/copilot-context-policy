# copilot-context-policy

[![ci](https://github.com/alfredoagrar/copilot-context-policy/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/alfredoagrar/copilot-context-policy/actions/workflows/ci.yml)

A versioned, multi-stack standard that keeps GitHub Copilot from spending tokens on **versioned files that add no value as context**: lock files, generated code, migration history, seed data, resources and heavy documentation. It also includes the tooling to roll it out and enforce it across an organization.

## Why

- Since June 1, 2026, Copilot bills by token consumption (GitHub AI Credits). Large generated or data files that end up in the context window cost money and add noise to suggestions.
- `.gitignore` does not help, because these files *are* committed.
- GitHub does **not** document `.copilotignore` as a natively enforced file. The official control is [Copilot Content Exclusion](https://docs.github.com/en/copilot/how-tos/configure-content-exclusion/exclude-content-from-copilot) (repository, organization or enterprise settings; Copilot Business/Enterprise).

This repository keeps the rules as **stack profiles** in [`templates/`](templates), which are the single source of truth. Each repository gets a `.copilotignore` composed from the profiles that match its stack, and the organization-level Content Exclusion YAML is generated from the same templates.

## Stack profiles

| Profile | Applied when the repository contains | Excludes, for example |
|---|---|---|
| [`common`](templates/common.copilotignore) | always | Lock files of every ecosystem, `*.min.js`, source maps, `swagger*.json`, `Generated/**`, localization catalogs, `migrations/**`, CSV/JSONL and seed data, `*.pdf`, `*.svg`, `*.drawio` |
| [`dotnet`](templates/dotnet.copilotignore) | `*.sln`, `*.slnx`, `*.csproj`, `*.fsproj`, `*.vbproj` | `*.resx`, `*.g.cs`, `*.Designer.cs`, `Connected Services/**`, `*.edmx`, `CompiledModels/**`, `wwwroot/lib/**`, SSDT post-deployment data |
| [`node`](templates/node.copilotignore) | `package.json` | Committed `dist/**`, `.yarn/releases/**`, `.pnp.cjs`, `__generated__/**`, `*.gen.ts`, Jest `__snapshots__/**` |
| [`python`](templates/python.copilotignore) | `pyproject.toml`, `setup.py`, `setup.cfg`, `requirements.txt`, `Pipfile` | `*_pb2.py`, `*_pb2_grpc.py`, `alembic/versions/**`, committed `site-packages/**` |
| [`java`](templates/java.copilotignore) | `pom.xml`, `build.gradle`, `build.gradle.kts` | `gradlew`, `mvnw`, wrapper jars, Flyway `db/migration/**`, Liquibase `db/changelog/**`, `generated-sources/**` |
| [`go`](templates/go.copilotignore) | `go.mod` | `vendor/**/*.go`, `*.pb.go`, `zz_generated*.go`, `mock_*.go`, `wire_gen.go` |

Profiles are declared in [`templates/profiles.json`](templates/profiles.json). A repository with a `.sln` and an Angular `ClientApp/package.json` gets `common + dotnet + node`. A repository with no recognized stack still gets `common`.

**Kept on purpose:** source code, including seeders, fixtures and test data builders; manifests (`package.json`, `*.csproj`, `pom.xml`, `go.mod`); schema and stored-procedure `.sql`; and Markdown docs such as READMEs and ADRs.

### Rule conventions

- Use the syntax subset that both gitignore and Content Exclusion (fnmatch) understand: an explicit `**/` or `/` anchor and no `!` negations.
- **Every rule must be safe for every stack.** Content Exclusion applies the union of all profiles to every repository and matches case-insensitively. For example, Go's vendor rule is `**/vendor/**/*.go` rather than `**/vendor/**`, so a `Domain/Vendor/` folder in a .NET repository stays visible.
- CI enforces both conventions. [`tests/fixtures/<profile>/`](tests/fixtures) lists paths each profile must exclude, and paths that must stay visible even under the case-insensitive union.

## Contents

| Path | Purpose |
|---|---|
| [`templates/`](templates) | `profiles.json` plus one `.copilotignore` template per profile. |
| [`scripts/Set-CopilotIgnore.ps1`](scripts/Set-CopilotIgnore.ps1) | Rollout script: detects stacks, then creates or updates `.copilotignore` append-only. |
| [`.github/workflows/copilotignore-check.yml`](.github/workflows/copilotignore-check.yml) | Reusable GitHub Actions workflow that fails PRs without a valid `.copilotignore`. |
| [`pipelines/github/copilotignore.yml`](pipelines/github/copilotignore.yml) | Consumer workflow that calls the reusable workflow. |
| [`pipelines/azure/`](pipelines/azure) | The same check as an Azure Pipelines step template, plus a consumer pipeline. |
| [`tests/`](tests) | Pester tests for the script, and pattern tests that use `git check-ignore` as the matching oracle. |

## Quick start

### 1. Roll out `.copilotignore`

```powershell
# Preview: nothing is written
./scripts/Set-CopilotIgnore.ps1 -RootPath C:\src -WhatIf

# Apply to every Git repository under C:\src (up to 2 levels deep), detecting stacks
./scripts/Set-CopilotIgnore.ps1 -RootPath C:\src

# From an explicit list; blank lines and '#' comments are ignored
Get-Content .\repos.txt | ./scripts/Set-CopilotIgnore.ps1 -PassThru | Export-Csv .\rollout.csv -NoTypeInformation

# Force the profiles instead of detecting them ('common' is always included)
./scripts/Set-CopilotIgnore.ps1 -RepositoryPath C:\src\portal -Stack dotnet, node
```

The script leaves changes uncommitted, so each team reviews and commits the file through its normal PR flow.

### 2. Apply the official Content Exclusion

```powershell
./scripts/Set-CopilotIgnore.ps1 -ContentExclusionOutFile .\content-exclusion.org.yml
```

This writes the union of all profiles under `"*"`. Paste it into **Organization settings > Copilot > Content exclusion**. Add `-Stack` to restrict it, for example for an organization that only builds .NET. Each release also attaches the full YAML as an asset.

### 3. Enforce it on pull requests

**GitHub Actions**: add [`pipelines/github/copilotignore.yml`](pipelines/github/copilotignore.yml) to each repository, or require it for the whole organization with *Rulesets > Require workflows to pass before merging*:

```yaml
jobs:
  copilotignore:
    uses: alfredoagrar/copilot-context-policy/.github/workflows/copilotignore-check.yml@v2
```

**Azure Pipelines**: reference the step template from this repository (see [`azure-pipelines.example.yml`](pipelines/azure/azure-pipelines.example.yml)) and register the pipeline as a *Build validation* branch policy. Azure Repos ignores the YAML `pr:` trigger.

## How the script behaves

- **Never overwrites.** A new file is created with `FileMode.CreateNew`. If the file already exists, only the missing rules of the detected profiles are appended, between `# >>> copilot-context-policy <version> [stacks] >>>` markers. Running it again changes nothing.
- **Grows with the repository.** Adding a front-end to a .NET repository and re-running the script appends only the `node` rules.
- **Preserves the existing file.** Encoding (UTF-8 with or without BOM, UTF-16) and line endings (CRLF/LF) are kept as they are.
- **Detects stacks cheaply.** Marker files are searched up to `-StackSearchDepth` levels deep (default 4). `bin/`, `obj/` and `node_modules/` are not searched.
- **Isolates failures.** A failing repository does not stop the others. The script ends with a summary table (including the stacks applied) and exits with code 1 if any repository failed.
- **Runs anywhere.** Windows PowerShell 5.1 and PowerShell 7+ on Windows, Linux and macOS. The file is ASCII-only on purpose.

### Opting out of a rule

Delete the rule from the repository's `.copilotignore` and add a marker so the script does not append it again:

```gitignore
# @disable **/*.svg
```

The marker only affects that repository's `.copilotignore`. An organization-level Content Exclusion still applies to every repository.

## Adding a stack

1. Create `templates/<name>.copilotignore`. Start it with a comment-only header block, then write sections as `# --- [<name>] Title ---` followed by rules.
2. Register the file and its marker files in `templates/profiles.json`.
3. Add `tests/fixtures/<name>/excluded.txt` and `included.txt`.
4. Bump the minor version. See [CONTRIBUTING.md](CONTRIBUTING.md#versioning).

## Known limitations

- Content Exclusion does not apply to **Agent mode in Copilot Chat in IDEs**. The Copilot app and Copilot CLI honor it since September 2, 2026.
- Rollout is append-only: **removing** a rule from a template does not remove it from repositories that already have it. That is why removals are major versions.
- Globs cannot express "large file". Add root-anchored paths for outliers under *Repository-specific rules* in each repository's file.
- Jupyter notebooks (`*.ipynb`) are not excluded, because in many data teams they are the code. Add them per repository if needed.

## Versioning

Releases follow SemVer and are cut from `main` with a `vX.Y.Z` tag that must match `version` in [`templates/profiles.json`](templates/profiles.json). The release workflow publishes the assets and moves the major tag (`v2`), which is the reference consumers should pin to.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). To propose a new rule or stack, open a [rule proposal](https://github.com/alfredoagrar/copilot-context-policy/issues/new?template=rule-proposal.yml).

## License

[MIT](LICENSE)
