---
id: 9EA18AEC-133A-4943-AD8F-1939D30C7D1F
created: 2026-07-17T11:00:00Z
modified: 2026-07-17T12:00:00Z
tags: [curl, staging]
golden: true
---
# Staging docs endpoint

Spent twenty minutes getting 401s from the staging gateway before I noticed it wants the bearer token *and* a tenant header — the production gateway infers the tenant from the key, staging does not. This is the invocation that finally returned documents.

```sh
curl -sS -H "Authorization: Bearer $STAGING_TOKEN" -H "X-Tenant: acme" \
  "https://staging.internal.example/api/v2/documents?limit=50" | jq '.items[]'
```

The token lives for an hour; mint a new one with the client-credentials call in the auth debugging note. Without `-sS` curl hides the error body behind a progress meter.
