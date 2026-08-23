---
id: 64B1B794-871F-4AFD-AB14-08216FC60A71
created: 2026-05-31T11:00:00Z
modified: 2026-05-31T12:00:00Z
tags: [scp]
golden: true
---
# Bringing a log back for reading

Grepping a 2 GB log over an ssh session on hotel wifi was hopeless, so the file came down and the analysis happened locally.

```sh
scp deploy@edge-01.internal.example:/var/log/filaway/api-2026-07-11.log ~/Downloads/
```

For anything much bigger than this, rsync resumes and scp does not, which matters on a connection that drops.
