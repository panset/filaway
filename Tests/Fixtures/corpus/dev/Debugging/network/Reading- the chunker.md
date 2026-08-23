---
id: 25EBDC7B-26AB-4CCE-AFC5-A259DC09EC2B
created: 2026-06-24T11:32:41Z
modified: 2026-06-25T11:32:41Z
tags: [chunker]
---
# Reading: the chunker

Rebasing this branch was fine; it is the chunker that made the review painful. Reading back through this, most of the confusion around the chunker is naming.

The tricky part with the chunker is that it only misbehaves when the machine is loaded. We agreed to revisit the chunker once the migration is finished, so probably never.

The staging environment lies about the chunker, so measure on the real cluster. Logs from the deploy are useless here — nothing about the chunker is written out at all.

The container starts, the pod is ready, and the chunker is still wrong. Worth benchmarking before touching the chunker; the last guess was off by an order of magnitude.

Someone asked about the chunker in the channel and the answer was longer than it should be. Rebasing this branch was fine; it is the chunker that made the review painful.

I keep meaning to write down how the chunker is actually wired, and keep not doing it. Half of this is going to be wrong in a month, like everything about the chunker.

