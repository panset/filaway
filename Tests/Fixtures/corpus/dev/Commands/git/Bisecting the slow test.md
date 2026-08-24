---
id: C78C6C4A-A861-4D05-ACD2-9BC17871251E
created: 2026-07-14T11:00:00Z
modified: 2026-07-14T12:00:00Z
tags: [git, testing]
golden: true
---
# Bisecting the slow test

The scale suite went from four seconds to nineteen somewhere in the last two hundred commits and nobody noticed. Rather than read the diff I let git binary-search it, running the suite at each step and letting the exit status decide the direction.

```sh
git bisect start HEAD v1.8.0
git bisect run swift test --filter SearchScaleTests
git bisect reset
```

Eight steps, four minutes, and it landed on the commit that added a per-row path normalisation. `git bisect run` needs the script to exit non-zero for "bad" — a test runner already does.
