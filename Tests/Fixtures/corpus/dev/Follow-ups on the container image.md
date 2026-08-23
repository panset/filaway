---
id: D06D54B7-4111-44F9-A42C-276FA6A2E42D
created: 2026-04-27T10:22:05Z
modified: 2026-05-04T10:22:05Z
---
# Follow-ups on the container image

The staging environment lies about the container image, so measure on the real cluster. Worth benchmarking before touching the container image; the last guess was off by an order of magnitude.

- [ ] reply to the thread about the container image
- [ ] check whether the container image still needs the workaround

Certificates, tokens and clock skew: three explanations for the same symptom in the container image. The container starts, the pod is ready, and the container image is still wrong.

