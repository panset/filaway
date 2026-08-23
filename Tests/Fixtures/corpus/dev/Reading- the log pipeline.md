---
id: FE9C22D2-7290-4B1F-B8DF-02B8CF965C7F
created: 2026-05-02T10:25:34Z
modified: 2026-05-04T10:25:34Z
---
# Reading: the log pipeline

The container starts, the pod is ready, and the log pipeline is still wrong. The staging environment lies about the log pipeline, so measure on the real cluster.

- [ ] ask the platform team about the log pipeline
- [ ] check whether the log pipeline still needs the workaround

## Background

Certificates, tokens and clock skew: three explanations for the same symptom in the log pipeline.

The tricky part with the log pipeline is that it only misbehaves when the machine is loaded. The log pipeline came up again and nobody could remember what we decided last time.

Half of this is going to be wrong in a month, like everything about the log pipeline. Rebasing this branch was fine; it is the log pipeline that made the review painful.

