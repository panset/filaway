---
id: 6EC764EE-C58F-436A-8E0D-3D7453826181
created: 2026-07-15T11:57:14Z
modified: 2026-07-15T11:57:14Z
---
# Reading: the vector store

There is a curl invocation somewhere in my history that would settle this about the vector store. I keep meaning to write down how the vector store is actually wired, and keep not doing it.

Every time the token expires I go looking for the same thing about the vector store. Someone asked about the vector store in the channel and the answer was longer than it should be.

```sh
kubectl get deploy -n prod
```

The staging environment lies about the vector store, so measure on the real cluster. The docs for the vector store describe the version before last, which cost me an hour.

We agreed to revisit the vector store once the migration is finished, so probably never. Half of this is going to be wrong in a month, like everything about the vector store.

