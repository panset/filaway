---
id: BF428201-EC0B-4CE3-AF94-A52B7F2A195D
created: 2026-07-02T11:14:54Z
modified: 2026-07-11T11:14:54Z
---
# Reading: the search panel

Rebasing this branch was fine; it is the search panel that made the review painful. Worth benchmarking before touching the search panel; the last guess was off by an order of magnitude.

```sh
npm run lint
```

The staging environment lies about the search panel, so measure on the real cluster. The tricky part with the search panel is that it only misbehaves when the machine is loaded.

- [ ] check whether the search panel still needs the workaround
- [ ] ask the platform team about the search panel

Certificates, tokens and clock skew: three explanations for the same symptom in the search panel. The container starts, the pod is ready, and the search panel is still wrong.

The docs for the search panel describe the version before last, which cost me an hour. I keep meaning to write down how the search panel is actually wired, and keep not doing it.

