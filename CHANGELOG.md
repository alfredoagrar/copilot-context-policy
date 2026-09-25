# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (see [CONTRIBUTING.md](CONTRIBUTING.md#versioning)).

## [Unreleased]

## [1.0.0] - 2026-09-25

### Added

- `templates/.copilotignore` standard for .NET repositories with 63 rules covering resources and translations, generated code, EF migrations, seed data and heavy documentation.
- `scripts/Set-CopilotIgnore.ps1`: append-only rollout across local repositories, `# @disable` opt-outs, and Content Exclusion YAML export.
- Reusable GitHub Actions workflow and Azure Pipelines step template that fail PRs without `.copilotignore`.
- CI with actionlint, yamllint, PSScriptAnalyzer and Pester on Linux, Windows PowerShell 5.1 and PowerShell 7.
- Release workflow that publishes assets and maintains the moving major tag.

[Unreleased]: https://github.com/alfredoagrar/copilot-context-policy/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/alfredoagrar/copilot-context-policy/releases/tag/v1.0.0
