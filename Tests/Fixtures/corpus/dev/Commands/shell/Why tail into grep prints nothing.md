---
id: A8C89AF2-CC48-434A-AEB4-E4AF24415246
created: 2026-05-10T11:00:00Z
modified: 2026-05-10T12:00:00Z
tags: [logs]
golden: true
---
# Why tail into grep prints nothing

Following a log through a filter and seeing absolutely nothing for minutes, then hundreds of lines at once. It is not the log and it is not the filter — it is that grep buffers its output when it is writing to a pipe rather than a terminal.

```sh
tail -F /var/log/app/api.log | grep --line-buffered -E 'WARN|ERROR'
```

`-F` rather than `-f` so it survives log rotation. The same buffering trap applies to `sed -u` and `awk` with `fflush()`.
