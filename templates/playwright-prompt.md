# Playwright Browser Exploration Instructions

Template for guiding the browser teammate through page exploration.

## Exploration Session: <TICKET-KEY>

### Login Sequence

1. Navigate to `<LOGIN_URL>`
2. Wait for login form to appear
3. Enter username: `<SANITY_USER>`
4. Enter password: `<USER_PASSWORD>`
5. Submit and wait for redirect to `<POST_LOGIN_URL>`
6. Close "What's New" dialog if it appears

### Target Pages

For each target page listed in triage.json:

#### Page: <page_url>

1. **Navigate**: Go to `<base_url><page_url>`
2. **Wait**: Wait for the page to fully load (no spinners, tables populated)
3. **Screenshot**: Take a full-page screenshot

4. **Catalog Elements**:

   **Navigation elements:**
   - Sidebar menu items (data-testid="menu-item-*")
   - Tab bars, breadcrumbs
   - Back/forward buttons

   **Action elements:**
   - Buttons (filter, export, create, delete)
   - Dropdown triggers
   - Toggle switches
   - Search inputs

   **Data display elements:**
   - Tables (headers, rows, cells)
   - Cards/tiles
   - Counters/badges
   - Charts/graphs
   - Status indicators

   **Form elements:**
   - Text inputs
   - Select dropdowns
   - Checkboxes/radios
   - Date pickers

5. **Interact** (safe actions only):
   - Click tabs to reveal sub-content, screenshot each
   - Open dropdowns to list options, screenshot
   - Click filter buttons to reveal filter panels, screenshot
   - Do NOT click delete, submit, or destructive actions

6. **Extract Locators** for each element:
   - Prefer `data-testid` attribute
   - Fallback to XPath with pipe (`|`) for alternatives
   - Note visible text content
   - Note aria-label if present

### Output Format

For each element found:
```json
{
    "name": "descriptive_camelCase_name",
    "type": "button|input|table|tab|dropdown|text|counter|link",
    "data_testid": "found-data-testid or null",
    "xpath": "//xpath/expression",
    "text": "visible text or null",
    "aria_label": "aria label or null",
    "page": "/page-url",
    "state": "default|hover|open|filtered"
}
```

### Selector Comparison

After gathering locators, compare against existing selectors:
- Read selector files from `framework/selectors/`
- Mark each found element as:
  - `reuse`: matches an existing selector (note the file and key)
  - `new`: no matching selector exists (suggest a key name and target file)
  - `update`: exists but selector value has changed (note old vs new)

### Safety Rules

- NEVER click "Delete", "Remove", or destructive buttons
- NEVER submit forms that create or modify data
- NEVER change settings or configurations
- ONLY interact with read-only elements (tabs, filters, dropdowns)
- If unsure whether an action is safe, skip it and note it for manual review
