---
id: 3945A304-BD5E-411F-B5E1-62EF57B0E725
created: 2026-06-25T11:02:49Z
modified: 2026-07-10T11:02:49Z
tags: [deploy-pipeline]
---
# Reading: the deploy pipeline

Certificates, tokens and clock skew: three explanations for the same symptom in the deploy pipeline. Logs from the deploy are useless here — nothing about the deploy pipeline is written out at all.

## Open questions

I keep meaning to write down how the deploy pipeline is actually wired, and keep not doing it.

The staging environment lies about the deploy pipeline, so measure on the real cluster. The container starts, the pod is ready, and the deploy pipeline is still wrong.

