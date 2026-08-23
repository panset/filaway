---
id: 001F7F0E-90F2-4AF6-AF3D-54848D988988
created: 2026-07-23T11:51:01Z
modified: 2026-07-28T11:51:01Z
tags: [cluster]
---
# Retro: the cluster

Rebasing this branch was fine; it is the cluster that made the review painful. Logs from the deploy are useless here — nothing about the cluster is written out at all.

I want a note that just holds the command, not an essay about the cluster. Certificates, tokens and clock skew: three explanations for the same symptom in the cluster.

The tricky part with the cluster is that it only misbehaves when the machine is loaded. Worth benchmarking before touching the cluster; the last guess was off by an order of magnitude.

```sh
curl -sS https://example.com/health
```

