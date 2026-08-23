---
id: 8225F7B1-4593-4931-9531-340934505656
created: 2026-07-31T10:41:59Z
modified: 2026-08-16T10:41:59Z
---
# Thinking about the certificate rotation

Logs from the deploy are useless here — nothing about the certificate rotation is written out at all. The staging environment lies about the certificate rotation, so measure on the real cluster.

Logs from the deploy are useless here — nothing about the certificate rotation is written out at all. Certificates, tokens and clock skew: three explanations for the same symptom in the certificate rotation.

Worth benchmarking before touching the certificate rotation; the last guess was off by an order of magnitude. Reading back through this, most of the confusion around the certificate rotation is naming.

Half of this is going to be wrong in a month, like everything about the certificate rotation. The staging environment lies about the certificate rotation, so measure on the real cluster.

```sh
make build
```

