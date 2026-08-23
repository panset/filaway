---
id: 06E354C0-C51C-4867-ABB1-3E1A16563332
created: 2026-08-01T11:07:42Z
modified: 2026-08-10T11:07:42Z
tags: [api-client]
---
# the api client — open questions

Reading back through this, most of the confusion around the api client is naming. The docs for the api client describe the version before last, which cost me an hour.

- [ ] reply to the thread about the api client
- [ ] write up what changed in the api client

I want a note that just holds the command, not an essay about the api client. Worth benchmarking before touching the api client; the last guess was off by an order of magnitude.

Certificates, tokens and clock skew: three explanations for the same symptom in the api client. Logs from the deploy are useless here — nothing about the api client is written out at all.

## Background

I keep meaning to write down how the api client is actually wired, and keep not doing it.

