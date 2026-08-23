---
id: EC0E83FD-537F-43E9-923B-A737C8953BE5
created: 2026-03-26T10:30:55Z
modified: 2026-03-26T10:30:55Z
---
# Standup 135

The tricky part with the certificate rotation is that it only misbehaves when the machine is loaded. We agreed to revisit the certificate rotation once the migration is finished, so probably never.

The certificate rotation came up again and nobody could remember what we decided last time. The staging environment lies about the certificate rotation, so measure on the real cluster.

The container starts, the pod is ready, and the certificate rotation is still wrong. Worth benchmarking before touching the certificate rotation; the last guess was off by an order of magnitude.

Certificates, tokens and clock skew: three explanations for the same symptom in the certificate rotation. We agreed to revisit the certificate rotation once the migration is finished, so probably never.

The container starts, the pod is ready, and the certificate rotation is still wrong. Half of this is going to be wrong in a month, like everything about the certificate rotation.

I keep meaning to write down how the certificate rotation is actually wired, and keep not doing it. Every time the token expires I go looking for the same thing about the certificate rotation.

