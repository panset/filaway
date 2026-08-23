---
id: 1B732CF7-68C2-4EA7-A9C4-6280EE698076
created: 2026-08-05T11:00:00Z
modified: 2026-08-05T12:00:00Z
tags: [kubernetes, postgres]
golden: true
---
# Reaching the staging database

The database has no external address, on purpose. To point a local client at it I forward the service port to a spare port on the laptop for as long as the command runs.

```sh
kubectl port-forward -n staging svc/postgres 55433:5432
```

Forward the *service*, not a pod, so a restart does not silently leave you connected to nothing. It dies with the terminal, which is the right default for this.
