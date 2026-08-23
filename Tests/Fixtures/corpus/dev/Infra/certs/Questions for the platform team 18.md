---
id: 49E583B0-757A-411D-B4F1-45B6F733E840
created: 2026-03-10T11:19:29Z
modified: 2026-03-23T11:19:29Z
---
# Questions for the platform team 18

Worth benchmarking before touching the search panel; the last guess was off by an order of magnitude. Logs from the deploy are useless here — nothing about the search panel is written out at all.

## Background

We agreed to revisit the search panel once the migration is finished, so probably never.

```sh
make build
```

The thing I actually needed was two directories up, filed under the search panel. Rebasing this branch was fine; it is the search panel that made the review painful.

