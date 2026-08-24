---
id: 5F372DC4-C4E0-4E0A-A6B7-42F631C3CA07
created: 2026-06-08T11:00:00Z
modified: 2026-06-08T12:00:00Z
tags: [curl, performance]
golden: true
---
# Where the request time goes

The mobile team said the ping endpoint felt slow from Europe. Before blaming the service I wanted the breakdown — name lookup, connect, and how long until the first byte of the response actually arrives.

```sh
curl -o /dev/null -sS -w 'dns=%{time_namelookup} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n' https://api.internal.example/v2/ping
```

It was DNS: 380 ms of the 500 ms was name resolution against a resolver in the wrong region. The service itself answered in 40 ms.
