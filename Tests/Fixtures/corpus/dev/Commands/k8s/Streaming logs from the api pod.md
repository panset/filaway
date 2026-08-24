---
id: C23EBD43-7336-4F49-8BD7-A606D715D10B
created: 2026-08-19T11:00:00Z
modified: 2026-08-19T12:00:00Z
tags: [kubernetes]
golden: true
---
# Streaming logs from the api pod

Watching a deploy go out. I want the output of the app container only — the sidecar is noisy — and only the recent past, because the pod has been up for days.

```sh
kubectl logs -f deploy/api -c app --since=15m -n staging
```

Pointing at the deployment rather than a pod name means it keeps working after a rollout replaces the pod. Add `--previous` to read the log of a container that crashed.
