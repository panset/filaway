---
id: F6721307-F023-41B8-84B0-8F694A720C83
created: 2026-03-09T11:43:32Z
modified: 2026-03-12T11:43:32Z
tags: [log-pipeline]
---
# Follow-ups on the log pipeline

Logs from the deploy are useless here — nothing about the log pipeline is written out at all. The tricky part with the log pipeline is that it only misbehaves when the machine is loaded.

Worth benchmarking before touching the log pipeline; the last guess was off by an order of magnitude. We agreed to revisit the log pipeline once the migration is finished, so probably never.

The container starts, the pod is ready, and the log pipeline is still wrong. The log pipeline came up again and nobody could remember what we decided last time.

We agreed to revisit the log pipeline once the migration is finished, so probably never. Half of this is going to be wrong in a month, like everything about the log pipeline.

## Open questions

Half of this is going to be wrong in a month, like everything about the log pipeline.

## Leftovers

There is a curl invocation somewhere in my history that would settle this about the log pipeline.

