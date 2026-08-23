---
id: 3A2D20F1-1D5B-4AA5-A343-CAE2F437FE74
created: 2026-04-11T10:11:55Z
modified: 2026-04-26T10:11:55Z
tags: [autosave-loop]
---
# Notes on the autosave loop

The docs for the autosave loop describe the version before last, which cost me an hour. The container starts, the pod is ready, and the autosave loop is still wrong.

Logs from the deploy are useless here — nothing about the autosave loop is written out at all. There is a curl invocation somewhere in my history that would settle this about the autosave loop.

## Next

The staging environment lies about the autosave loop, so measure on the real cluster.

Someone asked about the autosave loop in the channel and the answer was longer than it should be. Rebasing this branch was fine; it is the autosave loop that made the review painful.

We agreed to revisit the autosave loop once the migration is finished, so probably never. Half of this is going to be wrong in a month, like everything about the autosave loop.

Worth benchmarking before touching the autosave loop; the last guess was off by an order of magnitude. There is a curl invocation somewhere in my history that would settle this about the autosave loop.

