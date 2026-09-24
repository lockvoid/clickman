# Funnels

Funnels are JSON files in the host application, one funnel per file, by default
under `config/clickman/funnels/`. They are read at boot; there is no funnel
builder in the UI.

```json
{
  "key": "purchase",
  "name": "Purchase",
  "steps": [
    { "event": ["paywall_viewed", "upsell_shown"] },
    { "event": "purchase_started" },
    { "event": "purchase_completed", "where": { "store": "app_store" } }
  ],
  "window": "7d",
  "range": "90d",
  "breakdown": "context.os.name"
}
```

| Field | Rule |
|---|---|
| `key` | REQUIRED. `[a-z0-9_]+`, unique; the URL of the funnel. |
| `name` | REQUIRED. Shown in the UI. |
| `steps` | REQUIRED. 2–10 steps, in order. |
| `steps[].event` | REQUIRED. An event name, or a list of names any of which completes the step. |
| `steps[].where` | OPTIONAL. Property equality filters; a list value means any of. Keys are flattened keys (`context.app.version`). |
| `window` | OPTIONAL. Time allowed from the first step to the last: `<n>h` or `<n>d`, default `7d`. |
| `range` | OPTIONAL. How far back entries are counted, default `90d`. |
| `breakdown` | OPTIONAL. A flattened key to split the funnel by; the 10 most frequent values are shown. |

## Meaning

An actor enters the funnel on the day of their first step-1 event in the range.
Each later step counts if it happens after the previous one and within `window`
of entry. The anonymous actor `*` never enters a funnel.

The report stores, for the whole range, the actors that reached each step and
the median time between consecutive steps; the same step counts for every entry
day; and, with a `breakdown`, the step counts for each of its most frequent
values at entry. Reports are recomputed on every rotation and read from cache by
the dashboard.
