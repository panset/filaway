---
id: FA94599E-AB78-4542-9287-EFF4E2A9AA0B
created: 2026-05-26T11:00:00Z
modified: 2026-05-26T12:00:00Z
tags: [kubernetes]
golden: true
---
# Getting a heap dump off a pod

The dump is 900 MB inside a container with no shell tools and no network egress, so it has to come out through the API server rather than over scp.

```sh
kubectl cp staging/api-7f9c5d8b6-2xkqz:/tmp/heap.hprof ./heap.hprof
```

It needs `tar` present in the container image, which is easy to forget when the base is distroless. Slow, but it does not need anything opened up.
