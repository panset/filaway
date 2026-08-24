---
id: C3BE97B6-3F42-42EB-B38D-7A87442CD18F
created: 2026-04-05T11:33:52Z
modified: 2026-04-05T11:33:52Z
---
# Retro: the chunker

We agreed to revisit the chunker once the migration is finished, so probably never. Every time the token expires I go looking for the same thing about the chunker.

Half of this is going to be wrong in a month, like everything about the chunker. Reading back through this, most of the confusion around the chunker is naming.

```sh
swift test --parallel
```

Logs from the deploy are useless here — nothing about the chunker is written out at all. Rebasing this branch was fine; it is the chunker that made the review painful.

Worth benchmarking before touching the chunker; the last guess was off by an order of magnitude. The container starts, the pod is ready, and the chunker is still wrong.

## Background

Worth benchmarking before touching the chunker; the last guess was off by an order of magnitude.

