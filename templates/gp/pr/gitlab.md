# GitLab Merge Request Body Template

Use when creating MRs via `glab mr create`. Replace all `<PLACEHOLDER>` values.

---

## Summary

Automated test suite for **[<TICKET_ID>](<TICKET_URL>)**: <TICKET_TITLE>

<FEATURE_DOC>

---

## Test Results

| Metric | Value |
|--------|-------|
| **Framework** | <FRAMEWORK> |
| **Total Tests** | <TOTAL> |
| ✅ Passed | <PASSED> |
| ❌ Failed | 0 |
| Duration | <DURATION>s |

---

## What's Tested

<SCENARIO_LIST>

---

## Files Changed

```
tests/<feature>.spec.<ext>          New: <N> test cases
pages/<Feature>Page.<ext>           New: Page Object Model
config/selectors/<feature>.json     New: <N> element selectors
helpers/<feature>Helper.<ext>       New: helper functions
```

---

## Reports

- [Allure Report](<ALLURE_PATH>)
- [HTML Report](<HTML_PATH>)

---

> 🤖 GP Test Agent | Ticket: [<TICKET_ID>](<TICKET_URL>) | Framework: <FRAMEWORK>

/label ~"automated-test" ~"qa"
/assign @<REVIEWER>
