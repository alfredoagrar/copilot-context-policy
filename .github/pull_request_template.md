## What changes

<!-- Rules added/removed, script or pipeline changes, and why. -->

## Checklist

- [ ] Template rules keep the Content Exclusion-compatible subset (`**/` or `/` anchor, no `!`).
- [ ] New rules have a matching path in `tests/fixtures/expected-excluded.txt`; code that must stay visible is in `expected-included.txt`.
- [ ] `@standard-version` bumped per [CONTRIBUTING.md](../CONTRIBUTING.md#versioning) and `CHANGELOG.md` updated.
- [ ] `Set-CopilotIgnore.ps1` stays ASCII-only and compatible with Windows PowerShell 5.1.
