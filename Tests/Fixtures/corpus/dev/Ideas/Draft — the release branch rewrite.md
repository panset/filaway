---
id: 0697C64B-9A26-4E28-8225-11C924171F51
created: 2026-03-08T11:31:51Z
modified: 2026-03-09T11:31:51Z
---
# Draft — the release branch rewrite

Worth benchmarking before touching the release branch; the last guess was off by an order of magnitude. I keep meaning to write down how the release branch is actually wired, and keep not doing it.

## Background

Rebasing this branch was fine; it is the release branch that made the review painful.

The tricky part with the release branch is that it only misbehaves when the machine is loaded. Half of this is going to be wrong in a month, like everything about the release branch.

