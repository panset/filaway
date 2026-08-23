---
id: 7AF33761-A01B-4823-BBD8-977948396853
created: 2026-03-17T10:31:20Z
modified: 2026-04-02T10:31:20Z
tags: [release-branch]
---
# Thinking about the release branch

The container starts, the pod is ready, and the release branch is still wrong. Every time the token expires I go looking for the same thing about the release branch.

```sh
make build
```

Rebasing this branch was fine; it is the release branch that made the review painful. Certificates, tokens and clock skew: three explanations for the same symptom in the release branch.

Worth benchmarking before touching the release branch; the last guess was off by an order of magnitude. The tricky part with the release branch is that it only misbehaves when the machine is loaded.

## Decisions

There is a curl invocation somewhere in my history that would settle this about the release branch.

