---
id: F28338CE-88F0-4AD0-A3DF-5FE1691A834C
created: 2026-03-10T10:15:21Z
modified: 2026-03-21T10:15:21Z
---
# Draft — the certificate rotation rewrite

Rebasing this branch was fine; it is the certificate rotation that made the review painful. Reading back through this, most of the confusion around the certificate rotation is naming.

The container starts, the pod is ready, and the certificate rotation is still wrong. Reading back through this, most of the confusion around the certificate rotation is naming.

Logs from the deploy are useless here — nothing about the certificate rotation is written out at all. We agreed to revisit the certificate rotation once the migration is finished, so probably never.

Worth benchmarking before touching the certificate rotation; the last guess was off by an order of magnitude. Certificates, tokens and clock skew: three explanations for the same symptom in the certificate rotation.

The staging environment lies about the certificate rotation, so measure on the real cluster. Rebasing this branch was fine; it is the certificate rotation that made the review painful.

