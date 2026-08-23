---
id: 8860B5F0-83F9-40EB-A9C8-58F00D601C7D
created: 2026-05-04T11:50:08Z
modified: 2026-05-16T11:50:08Z
tags: [api-client]
---
# Untitled 112

The api client came up again and nobody could remember what we decided last time. I keep meaning to write down how the api client is actually wired, and keep not doing it.

The api client came up again and nobody could remember what we decided last time. Certificates, tokens and clock skew: three explanations for the same symptom in the api client.

Rebasing this branch was fine; it is the api client that made the review painful. The staging environment lies about the api client, so measure on the real cluster.

Logs from the deploy are useless here — nothing about the api client is written out at all. Worth benchmarking before touching the api client; the last guess was off by an order of magnitude.

The thing I actually needed was two directories up, filed under the api client. Every time the token expires I go looking for the same thing about the api client.

The api client came up again and nobody could remember what we decided last time. I keep meaning to write down how the api client is actually wired, and keep not doing it.

