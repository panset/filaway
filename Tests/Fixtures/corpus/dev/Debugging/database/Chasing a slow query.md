---
id: 4584FD8A-0534-4C86-82D0-611D366AF138
created: 2026-07-01T11:00:00Z
modified: 2026-07-01T12:00:00Z
tags: [postgres, performance]
golden: true
---
# Chasing a slow query

The recents list took 900 ms on staging and 4 ms locally, and the only difference was row count. Reading the plan the planner actually chose — with real timings and the buffer counts, not the estimates — showed a sequential scan over the whole table because the index on the modification column had never been created there.

```sh
psql "$DATABASE_URL" -X -c "explain (analyze, buffers) select id from notes where mtime > now() - interval '7 days';"
```

`analyze` runs the query for real, so never do this to a statement that writes. `buffers` is what tells you whether the pages came from cache or from disk. After the index: 900 ms to 3 ms, and the buffer count fell by four orders of magnitude.
