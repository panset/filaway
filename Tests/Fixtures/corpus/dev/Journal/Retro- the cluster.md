---
id: 17A8E603-558D-4CBB-8155-2F1FBFB8656B
created: 2026-06-14T10:25:44Z
modified: 2026-06-25T10:25:44Z
---
# Retro: the cluster

The tricky part with the cluster is that it only misbehaves when the machine is loaded. Certificates, tokens and clock skew: three explanations for the same symptom in the cluster.

Reading back through this, most of the confusion around the cluster is naming. The cluster came up again and nobody could remember what we decided last time.

We agreed to revisit the cluster once the migration is finished, so probably never. I want a note that just holds the command, not an essay about the cluster.

```sh
kubectl get deploy -n prod
```

