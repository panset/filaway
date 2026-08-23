---
id: E05E44E3-F657-4B20-AA5B-63A2948A598E
created: 2026-07-01T11:27:23Z
modified: 2026-07-11T11:27:23Z
---
# Questions for the platform team 61

There is a curl invocation somewhere in my history that would settle this about the vector store. Reading back through this, most of the confusion around the vector store is naming.

## Next

The vector store came up again and nobody could remember what we decided last time.

The container starts, the pod is ready, and the vector store is still wrong. Logs from the deploy are useless here — nothing about the vector store is written out at all.

Every time the token expires I go looking for the same thing about the vector store. We agreed to revisit the vector store once the migration is finished, so probably never.

```sh
make build
```

Worth benchmarking before touching the vector store; the last guess was off by an order of magnitude. The tricky part with the vector store is that it only misbehaves when the machine is loaded.

