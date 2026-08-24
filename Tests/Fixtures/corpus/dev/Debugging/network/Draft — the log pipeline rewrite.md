---
id: D65FB7E6-DBE9-48AF-8F18-0AFACC08479F
created: 2026-05-12T11:21:22Z
modified: 2026-05-17T11:21:22Z
---
# Draft — the log pipeline rewrite

We agreed to revisit the log pipeline once the migration is finished, so probably never. I want a note that just holds the command, not an essay about the log pipeline.

Rebasing this branch was fine; it is the log pipeline that made the review painful. Certificates, tokens and clock skew: three explanations for the same symptom in the log pipeline.

Rebasing this branch was fine; it is the log pipeline that made the review painful. The tricky part with the log pipeline is that it only misbehaves when the machine is loaded.

The staging environment lies about the log pipeline, so measure on the real cluster. Someone asked about the log pipeline in the channel and the answer was longer than it should be.

```sh
brew update
```

