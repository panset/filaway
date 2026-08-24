---
id: 98C212AF-CF57-43E9-813F-856D4BD5AC4E
created: 2026-07-24T11:00:00Z
modified: 2026-07-24T12:00:00Z
tags: [sed, ripgrep]
golden: true
---
# Renaming a symbol across the repo

No IDE refactor available on this machine, and the name appears in comments and documentation as well as code, so a compiler-aware rename would have missed half of it.

```sh
rg -l 'candidateLimit' Sources | xargs sed -i '' 's/candidateLimit/candidatePerArm/g'
```

The empty `''` after `-i` is BSD sed's mandatory backup suffix — GNU sed does not want it, which is why this line is wrong on Linux. Commit first, then run it, then diff.
