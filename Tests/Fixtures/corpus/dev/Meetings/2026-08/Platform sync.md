---
id: 73EA418A-0919-4AA3-966F-45E24C94A872
created: 2026-08-09T11:00:00Z
modified: 2026-08-09T12:00:00Z
tags: [meeting, kubernetes]
golden: true
---
# Platform sync

Platform are moving staging to the new cluster in Ireland on the first of next month. The old context keeps working until then and is then deleted, so everyone's kubeconfig needs the new one added and selected. Priya shared the two lines to run.

```sh
kubectl config use-context staging-eu-west-1
kubectl config get-contexts
```

Other items: the log retention drops to seven days, the shared postgres gets a read replica, and the on-call rotation moves to two-week blocks from September.
