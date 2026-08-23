---
id: 0564F3FF-6833-4F05-8364-2CFCA799B9AC
created: 2026-08-18T11:00:00Z
modified: 2026-08-18T12:00:00Z
tags: [auth, curl]
golden: true
---
# Auth API 401 session

Half a day on this. Every call to the documents endpoint came back 401 with an empty body, which the gateway does for both "no token" and "expired token" — the two cases that need completely different fixes. The token in my environment had been minted on Monday and the lifetime is an hour, so it had been dead for three days and I had been reading the request headers for signs of a typo. Minting a fresh one takes one call against the client-credentials grant, and the response carries the expiry so a script can decide when to do it again.

```sh
curl -sS -X POST -u "$CLIENT_ID:$CLIENT_SECRET" -d 'grant_type=client_credentials' https://auth.internal.example/oauth2/token
```

The credentials go in the Basic header via `-u`, not in the body, which is what the provider's own documentation gets wrong. Filed a ticket asking for a distinct status or an error body on expiry; without one this will cost somebody else the same day.
