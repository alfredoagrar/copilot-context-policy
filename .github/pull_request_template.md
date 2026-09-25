## What changes

<!-- Rules added/removed, script or pipeline changes, and why. -->

## Checklist

- [ ] Rules live in the narrowest profile and keep the Content Exclusion-compatible subset (`**/` or `/` anchor, no `!`).
- [ ] Rules are safe for every stack under the case-insensitive union (Content Exclusion applies all profiles to all repositories).
- [ ] New rules have a matching path in `tests/fixtures/<profile>/excluded.txt`; code that must stay visible is in `included.txt`.
- [ ] `version` in `templates/profiles.json` bumped per [CONTRIBUTING.md](../CONTRIBUTING.md#versioning) and `CHANGELOG.md` updated.
- [ ] `Set-CopilotIgnore.ps1` stays ASCII-only and compatible with Windows PowerShell 5.1.
