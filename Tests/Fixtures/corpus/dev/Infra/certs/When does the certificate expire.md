---
id: 72A4704A-1392-45D7-A8A0-45D039474399
created: 2026-08-17T11:00:00Z
modified: 2026-08-17T12:00:00Z
tags: [openssl, tls]
golden: true
---
# When does the certificate expire

The monitoring alert for certificate expiry has been broken since June, so before the release I checked the staging endpoint by hand. The subject line matters as much as the dates — the wrong certificate for the right host is the failure mode nobody looks for.

```sh
openssl s_client -connect api.internal.example:443 -servername api.internal.example </dev/null 2>/dev/null | openssl x509 -noout -dates -subject
```

`-servername` sends SNI; without it a shared front end hands back its default certificate and the answer is meaningless. Nineteen days left, renewal is automated.
