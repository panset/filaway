---
id: C7A6731B-B35E-4451-9E42-3F5CB67F6F4E
created: 2026-04-23T10:34:03Z
modified: 2026-05-04T10:34:03Z
tags: [cluster]
---
# Notes on the cluster

The container starts, the pod is ready, and the cluster is still wrong. Certificates, tokens and clock skew: three explanations for the same symptom in the cluster.

The thing I actually needed was two directories up, filed under the cluster. Half of this is going to be wrong in a month, like everything about the cluster.

## Background

Someone asked about the cluster in the channel and the answer was longer than it should be.

Worth benchmarking before touching the cluster; the last guess was off by an order of magnitude. The tricky part with the cluster is that it only misbehaves when the machine is loaded.

```sh
curl -sS https://example.com/health
```

## Decisions

The staging environment lies about the cluster, so measure on the real cluster.

