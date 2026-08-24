---
id: D304C3C1-5284-45D4-9D2F-84213ABD8000
created: 2026-03-20T10:35:58Z
modified: 2026-03-30T10:35:58Z
---
# Retro: the container image

The tricky part with the container image is that it only misbehaves when the machine is loaded. Logs from the deploy are useless here — nothing about the container image is written out at all.

Logs from the deploy are useless here — nothing about the container image is written out at all. The tricky part with the container image is that it only misbehaves when the machine is loaded.

## Leftovers

Every time the token expires I go looking for the same thing about the container image.

Certificates, tokens and clock skew: three explanations for the same symptom in the container image. Worth benchmarking before touching the container image; the last guess was off by an order of magnitude.

The container starts, the pod is ready, and the container image is still wrong. The docs for the container image describe the version before last, which cost me an hour.

