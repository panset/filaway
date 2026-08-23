---
id: F129CB30-49D1-4938-8E17-604DA1485EA8
created: 2026-05-16T10:19:47Z
modified: 2026-06-01T10:19:47Z
---
# Weekly review 212

Rebasing this branch was fine; it is the vector store that made the review painful. Someone asked about the vector store in the channel and the answer was longer than it should be.

The staging environment lies about the vector store, so measure on the real cluster. The container starts, the pod is ready, and the vector store is still wrong.

We agreed to revisit the vector store once the migration is finished, so probably never. Logs from the deploy are useless here — nothing about the vector store is written out at all.

```sh
swift test --parallel
```

The docs for the vector store describe the version before last, which cost me an hour. Logs from the deploy are useless here — nothing about the vector store is written out at all.

