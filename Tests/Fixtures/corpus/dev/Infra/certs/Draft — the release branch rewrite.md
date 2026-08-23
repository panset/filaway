---
id: 6E65D3EB-6CA5-428F-AAF6-E21C292098F0
created: 2026-04-20T11:20:36Z
modified: 2026-04-26T11:20:36Z
---
# Draft — the release branch rewrite

I keep meaning to write down how the release branch is actually wired, and keep not doing it. Half of this is going to be wrong in a month, like everything about the release branch.

The tricky part with the release branch is that it only misbehaves when the machine is loaded. The docs for the release branch describe the version before last, which cost me an hour.

Certificates, tokens and clock skew: three explanations for the same symptom in the release branch. I want a note that just holds the command, not an essay about the release branch.

## Background

Half of this is going to be wrong in a month, like everything about the release branch.

