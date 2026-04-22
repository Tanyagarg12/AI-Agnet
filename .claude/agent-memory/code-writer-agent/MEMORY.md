# Code Writer Agent Memory

## Git Branch Creation
- Cannot checkout protected branches (developmentV2, main, etc.) due to PreToolUse hook
- Must use `git checkout -b <branch> origin/developmentV2` to create feature branch directly
- Always `git fetch origin developmentV2` first, then branch from `origin/developmentV2`
- Stash any existing changes before switching branches

## Framework File Sizes
- `selectors/issues.json` ~1315 lines -- too large for full read, use offset/limit
- `actions/issues.js` ~16500+ lines -- too large for full read, use grep + offset/limit
- Always re-read file endings on the actual branch before editing (line counts differ between branches)

## issues.json Structure
- Flat JSON object (no nesting for most selectors)
- Has one nested object: `"issueCard": { ... }` around line 1290
- Owner-related selectors at the very end (lines 1306-1314)
- Add new selectors before the closing `}`

## actions/issues.js Structure
- Imports at top: expect, fs, path, Papa, pdfParse, logger, selectors, params
- `shortTimeout`, `longTimeout`, `mediumTimeout` from `params/global.json`
- `module.exports` at very end -- add new function names there
- Owner functions (updateIssueOwner, resetOwner, revertOwnerChange, filterByIssueOwner) near end ~line 16164+

## Test File Style (issuesV2 pattern)
- Variables declared with `let` using comma-separated declaration
- `process.env.TEST_NAME = testName;` after variable declarations
- Imports use comma-separated `const` declaration
- `test.describe.configure({ mode: "serial", retries: 1 })` (retries: 1, not 0)
- `setBeforeAll` called with 5 args (no 6th boolean arg) in this pattern
- `process.env.testName = testName;` at the very end of file
- Test numbering allows sub-steps like #3.1, #5.1
