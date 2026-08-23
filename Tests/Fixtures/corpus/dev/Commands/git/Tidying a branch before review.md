---
id: 4F002A80-2670-43EB-930F-8D1E5C085471
created: 2026-06-15T11:00:00Z
modified: 2026-06-15T12:00:00Z
tags: [git]
golden: true
---
# Tidying a branch before review

Fourteen commits, eleven of them "wip" and "fix typo". The reviewer wants three commits that each do one thing, so the branch gets squashed before it goes up.

```sh
git rebase -i HEAD~4
git push --force-with-lease origin feature/chunker
```

`--force-with-lease` rather than `--force`: it refuses if someone else pushed to the branch in the meantime, which is the only thing that makes force-pushing a shared branch survivable.
