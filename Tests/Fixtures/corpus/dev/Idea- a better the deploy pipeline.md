---
id: 13D744DE-E115-4412-8A2F-F204A5C8A52C
created: 2026-06-01T10:02:10Z
modified: 2026-06-03T10:02:10Z
---
# Idea: a better the deploy pipeline

The docs for the deploy pipeline describe the version before last, which cost me an hour. There is a curl invocation somewhere in my history that would settle this about the deploy pipeline.

The thing I actually needed was two directories up, filed under the deploy pipeline. Someone asked about the deploy pipeline in the channel and the answer was longer than it should be.

Worth benchmarking before touching the deploy pipeline; the last guess was off by an order of magnitude. We agreed to revisit the deploy pipeline once the migration is finished, so probably never.

The tricky part with the deploy pipeline is that it only misbehaves when the machine is loaded. Logs from the deploy are useless here — nothing about the deploy pipeline is written out at all.

The staging environment lies about the deploy pipeline, so measure on the real cluster. Someone asked about the deploy pipeline in the channel and the answer was longer than it should be.

