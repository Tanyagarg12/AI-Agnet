# Git Safety Rules

These rules protect the e2e framework repository from dangerous operations.

## Protected Branches -- NEVER commit or push to:
- `developmentV2`
- `development`
- `main`
- `master`
- Any branch matching `release/*`

## ALWAYS
- Create a new side branch from `origin/developmentV2` (fetch first, never checkout):
  ```bash
  git fetch origin developmentV2
  git checkout -b test/OXDEV-<num>-<slug> origin/developmentV2
  ```
- Branch naming: `test/OXDEV-<num>-<slug>` (or feat/, fix/, chore/ per ticket type)
- Use conventional commit messages: `<type>(<scope>): <description>`
- Push to origin with the side branch name

## NEVER Do
- NEVER force-push (`git push --force` or `git push -f`)
- NEVER delete remote branches
- NEVER merge branches (MR reviewers do this)
- NEVER checkout protected branches (`git checkout developmentV2` is blocked by hook — use `origin/developmentV2` as base instead)
- NEVER modify playwright.config.js unless the ticket specifically requires it
- NEVER commit .env files, secrets, tokens, or credentials

## Branch Naming Convention
| Ticket Type | Branch Prefix | Example                          |
|-------------|---------------|----------------------------------|
| feature     | feat/         | feat/OXDEV-123-add-cloud-scan    |
| bug         | fix/          | fix/OXDEV-456-null-pointer       |
| refactor    | chore/        | chore/OXDEV-789-cleanup-api      |
| test        | test/         | test/OXDEV-012-add-unit-tests    |
| docs        | chore/        | chore/OXDEV-345-update-readme    |

Required format: `<prefix>/OXDEV-<number>-<short-description>`

## MR Target Branch
- Default: `developmentV2`
- Do NOT target `main`, `master`, `development`, or any other branch
