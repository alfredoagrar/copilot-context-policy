# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (see [CONTRIBUTING.md](CONTRIBUTING.md#versioning)).

## [Unreleased]

## [2.0.0] - 2026-09-25

### Added

- Stack profiles in `templates/profiles.json`: `common` (always applied, usable on its own for any repository) plus `dotnet`, `node`, `python`, `java` and `go`, detected from marker files.
- Lock files of every ecosystem, gettext catalogs and Terraform lock files in `common`.
- `-Stack` parameter to force profiles, and a `Stacks` column in the results.
- Pattern tests per profile, plus a cross-stack safety test that checks every "must stay visible" path against the case-insensitive union of all profiles, the way Content Exclusion applies it.

### Changed

- **Breaking:** the script now processes every Git repository, not only .NET ones. Repositories with no recognized stack receive the `common` profile.
- **Breaking:** `-TemplatePath` is replaced by `-TemplateDirectory`, and `-ProjectSearchDepth` by `-StackSearchDepth`.
- **Breaking:** `templates/.copilotignore` is split into `templates/common.copilotignore` and `templates/dotnet.copilotignore`. Every v1 rule is kept, so upgrading a v1 file only appends new rules.
- Append markers are now `# >>> copilot-context-policy <version> [stacks] >>>`.
- `-ContentExclusionOutFile` exports the union of all profiles, or of `-Stack`.

## [1.0.0] - 2026-09-25

### Added

- `templates/.copilotignore` standard for .NET repositories with 63 rules covering resources and translations, generated code, EF migrations, seed data and heavy documentation.
- `scripts/Set-CopilotIgnore.ps1`: append-only rollout across local repositories, `# @disable` opt-outs, and Content Exclusion YAML export.
- Reusable GitHub Actions workflow and Azure Pipelines step template that fail PRs without `.copilotignore`.
- CI with actionlint, yamllint, PSScriptAnalyzer and Pester on Linux, Windows PowerShell 5.1 and PowerShell 7.
- Release workflow that publishes assets and maintains the moving major tag.

[Unreleased]: https://github.com/alfredoagrar/copilot-context-policy/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/alfredoagrar/copilot-context-policy/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/alfredoagrar/copilot-context-policy/releases/tag/v1.0.0
