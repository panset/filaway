---
id: C4351068-A42E-4796-8D2C-A3EE2B0DA701
created: 2026-07-07T11:00:00Z
modified: 2026-07-07T12:00:00Z
tags: [kubernetes]
golden: true
---
# Finding the pod that keeps dying

Something in the namespace was restarting in a loop and the dashboard was down. Listing everything that is not currently running narrows it to one pod immediately, and the events at the bottom of the description say why.

```sh
kubectl get pods -n staging --field-selector=status.phase!=Running
kubectl describe pod api-7f9c5d8b6-2xkqz -n staging | sed -n '/Events/,$p'
```

It was an OOMKill: the memory limit was set from a measurement taken before the vector matrix was loaded eagerly. Events are only kept for an hour, so look early.
