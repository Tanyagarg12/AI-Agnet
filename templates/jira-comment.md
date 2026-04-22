# Jira Comment Templates

All Jira comments from agents MUST use one of these templates.
Format rule: `**[QA Agent: <agent-name>]** <ISO-8601 timestamp>`

---

## Triage Complete

```
**[QA Agent: triage-agent]** <timestamp>

**Triage Complete**

| Field        | Value                                         |
|--------------|-----------------------------------------------|
| Feature area | <issues|sbom|dashboard|policies|settings|...> |
| Test type    | <ui|api|mixed>                                |
| Complexity   | <S|M|L>                                       |
| Target pages | <page list>                                   |
| Baseline     | <yes|no>                                      |

**Pipeline**: triage > explorer > playwright > code-writer > test-runner > pr
```

## Pipeline Stage Update

```
**[QA Agent: <agent-name>]** <timestamp>

**Stage: <stage-name>** -- <completed|failed>

<1-3 sentence summary of what was done or what went wrong>
```

## Test Results

```
**[QA Agent: test-runner]** <timestamp>

**Test Execution Results**

| Field    | Value         |
|----------|---------------|
| Status   | <PASS|FAIL>   |
| Total    | <N>           |
| Passed   | <N>           |
| Failed   | <N>           |
| Duration | <N>ms         |
| Env      | <environment> |

<If FAIL: list of failing test names and error summaries>
```

## Debug Cycle

```
**[QA Agent: debug-agent]** <timestamp>

**Debug Cycle <N>/3** -- <fixed|still failing>

**Root cause**: <one-line description>
**Fix applied**: <one-line description>
**Tests after fix**: <N> passed, <N> failed
```

## MR Created

```
**[QA Agent: pr-agent]** <timestamp>

**Merge Request Created**

| Field      | Value               |
|------------|---------------------|
| MR         | <MR-URL>            |
| Branch     | `<branch-name>`     |
| Target     | `development`       |
| Tests      | <N> passed          |
```

## Pipeline Failed

```
**[QA Agent: <agent-name>]** <timestamp>

**Pipeline Failed at Stage: <stage-name>**

**Error**: <one-line error summary>

**Details**:
<2-5 lines describing the failure, what was attempted, and suggested next steps>

Label `ai-failed` has been applied.
```

## Pipeline Complete

```
**[QA Agent: pipeline-lead]** <timestamp>

**E2E Test Pipeline Complete**

| Field        | Value                    |
|--------------|--------------------------|
| Test file    | <path>                   |
| MR           | <MR-URL>                 |
| Tests        | <N> passed               |
| Debug cycles | <N>                      |
| Duration     | <total pipeline time>    |
```

---

## Rules

- Always use UTC timestamps in ISO-8601 format
- Never include raw stack traces or internal file paths in comments
- Keep comments concise -- link to the MR for details
- One comment per stage transition (do not spam the ticket)
