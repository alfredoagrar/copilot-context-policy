# Contributing

## Branches

| Branch | Purpose | Protection |
|---|---|---|
| `main` | Released code. Every commit on `main` can be tagged. | PR required, CI must pass, no force-push or deletion |
| `develop` | Integration branch for the next release. | PR required, CI must pass, no force-push or deletion |
| `feature/*`, `fix/*`, `docs/*` | Short-lived work branches cut from `develop`. | – |

Flow: `feature/*` → PR into `develop` → PR from `develop` into `main` → tag `vX.Y.Z` on `main`.

Required checks: `Lint` and the three `Pester (...)` jobs from [`ci.yml`](.github/workflows/ci.yml).

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `ci:`, `test:`, `chore:`). Release notes are generated from PR titles, so give each PR a meaningful title.

## Versioning

`version` in `templates/profiles.json` is the product version. Consumer repositories receive changes append-only, which drives the rules below:

| Change | Bump |
|---|---|
| Comments, docs, CI, script fixes with no behavior change | patch |
| New rule, new stack profile, or a new backwards-compatible script feature | minor |
| Rule removed or narrowed, or a breaking script change | **major**, because existing repositories keep the old rule until someone removes it by hand |

## Adding or changing a rule

1. Put the rule in the narrowest profile that needs it (`templates/<profile>.copilotignore`). A rule belongs in exactly one template.
2. Keep the compatible syntax: an explicit `**/` or `/` anchor and no `!`.
3. Make it safe for **every** stack. The organization-level Content Exclusion applies the union of all profiles to every repository, case-insensitively. For example, prefer `**/vendor/**/*.go` over `**/vendor/**`.
4. Add at least one path the rule must exclude to `tests/fixtures/<profile>/excluded.txt`, and nearby code that must stay visible to `tests/fixtures/<profile>/included.txt`.
5. Bump `version` in `templates/profiles.json` and update `CHANGELOG.md`.

To add a new stack, see [Adding a stack](README.md#adding-a-stack).

## Running checks locally

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester ./tests -Output Detailed

Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path ./scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

## Releasing

```bash
git switch main && git pull
git tag v2.1.0 && git push origin v2.1.0
```

The [`release`](.github/workflows/release.yml) workflow checks that the tag is on `main` and matches `version` in `templates/profiles.json`. It then publishes the release assets and moves the major tag (for example `v2`) to the new commit.
