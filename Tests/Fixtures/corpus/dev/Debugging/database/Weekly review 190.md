---
id: 332EE6D9-D64D-44AD-A80E-F28E2E50139E
created: 2026-06-13T10:04:29Z
modified: 2026-06-20T10:04:29Z
tags: [token-budget]
---
# Weekly review 190

Half of this is going to be wrong in a month, like everything about the token budget. The staging environment lies about the token budget, so measure on the real cluster.

The container starts, the pod is ready, and the token budget is still wrong. The thing I actually needed was two directories up, filed under the token budget.

```sh
kubectl get deploy -n prod
```

Rebasing this branch was fine; it is the token budget that made the review painful. Every time the token expires I go looking for the same thing about the token budget.

Rebasing this branch was fine; it is the token budget that made the review painful. The tricky part with the token budget is that it only misbehaves when the machine is loaded.

