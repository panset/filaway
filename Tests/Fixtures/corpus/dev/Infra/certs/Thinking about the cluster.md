---
id: 017289D5-DC1C-4D8A-9652-67685B11985A
created: 2026-04-16T10:01:11Z
modified: 2026-04-20T10:01:11Z
tags: [cluster]
---
# Thinking about the cluster

Certificates, tokens and clock skew: three explanations for the same symptom in the cluster. The container starts, the pod is ready, and the cluster is still wrong.

## Leftovers

Worth benchmarking before touching the cluster; the last guess was off by an order of magnitude.

The staging environment lies about the cluster, so measure on the real cluster. I keep meaning to write down how the cluster is actually wired, and keep not doing it.

Logs from the deploy are useless here — nothing about the cluster is written out at all. Someone asked about the cluster in the channel and the answer was longer than it should be.

## Leftovers

Reading back through this, most of the confusion around the cluster is naming.

The staging environment lies about the cluster, so measure on the real cluster. The tricky part with the cluster is that it only misbehaves when the machine is loaded.

