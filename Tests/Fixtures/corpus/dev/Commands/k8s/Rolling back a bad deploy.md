---
id: 74BC42D0-E285-4292-AE37-D823E223C492
created: 2026-07-18T11:00:00Z
modified: 2026-07-18T12:00:00Z
tags: [kubernetes, release]
golden: true
---
# Rolling back a bad deploy

Error rate went vertical ninety seconds after the deploy. Rolling forward with a fix would have taken twenty minutes of CI; going back to the previous replica set took one command and about fifteen seconds.

```sh
kubectl rollout undo deploy/api -n staging
kubectl rollout status deploy/api -n staging
```

`rollout status` blocks until the new pods are actually ready, so it is the line to put in a script. Only the last ten revisions are kept by default.
