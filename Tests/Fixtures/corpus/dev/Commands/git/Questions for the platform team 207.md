---
id: F39AB62C-902C-4B30-B044-F2419CD2031F
created: 2026-07-20T10:49:04Z
modified: 2026-07-24T10:49:04Z
---
# Questions for the platform team 207

The autosave loop came up again and nobody could remember what we decided last time. The container starts, the pod is ready, and the autosave loop is still wrong.

```sh
make smoke
```

Rebasing this branch was fine; it is the autosave loop that made the review painful. Half of this is going to be wrong in a month, like everything about the autosave loop.

Worth benchmarking before touching the autosave loop; the last guess was off by an order of magnitude. Rebasing this branch was fine; it is the autosave loop that made the review painful.

Logs from the deploy are useless here — nothing about the autosave loop is written out at all. I want a note that just holds the command, not an essay about the autosave loop.

