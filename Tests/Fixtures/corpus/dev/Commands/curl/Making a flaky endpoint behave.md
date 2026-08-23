---
id: ACA63562-AF66-466F-9EDF-DCD604AF6DED
created: 2026-05-24T11:00:00Z
modified: 2026-05-24T12:00:00Z
tags: [curl]
golden: true
---
# Making a flaky endpoint behave

The health endpoint drops roughly one request in five while the pool warms up, which made the deploy script fail for no reason. Rather than wrap it in a shell loop I let curl do the retrying, including on connection resets, which it will not do by default.

```sh
curl --retry 5 --retry-all-errors --retry-delay 2 --max-time 30 -sS https://flaky.internal.example/health
```

`--retry` alone only retries transient HTTP statuses; the reset was a transport error, which is what `--retry-all-errors` covers. Always pair it with a total timeout.
