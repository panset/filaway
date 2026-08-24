---
id: 3DF09D5B-1336-430C-BD01-4B53010F9301
created: 2026-06-12T11:00:00Z
modified: 2026-06-12T12:00:00Z
tags: [kubernetes]
golden: true
---
# What environment does this pod see

The config map was updated but the behaviour did not change, which usually means the pod was never restarted and is still holding the old values in its environment.

```sh
kubectl exec -it -n staging deploy/api -- sh -lc 'env | sort'
```

The `--` separates kubectl's flags from the command; without it the flags after it get eaten. Sorting makes the diff against the expected set readable.
