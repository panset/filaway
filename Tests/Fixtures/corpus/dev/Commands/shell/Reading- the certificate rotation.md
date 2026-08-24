---
id: 84D39DC0-0C1F-43EA-8749-5658D6F01D1A
created: 2026-05-07T11:45:50Z
modified: 2026-05-17T11:45:50Z
---
# Reading: the certificate rotation

Logs from the deploy are useless here — nothing about the certificate rotation is written out at all. The tricky part with the certificate rotation is that it only misbehaves when the machine is loaded.

The staging environment lies about the certificate rotation, so measure on the real cluster. The docs for the certificate rotation describe the version before last, which cost me an hour.

The thing I actually needed was two directories up, filed under the certificate rotation. Certificates, tokens and clock skew: three explanations for the same symptom in the certificate rotation.

