---
id: F9656D52-D6A7-4FD4-9A2C-44F6E29C3EE1
created: 2026-07-22T11:00:00Z
modified: 2026-07-22T12:00:00Z
tags: [git]
golden: true
---
# Rebasing onto main without losing work

My branch was forty commits behind and a merge would have made the history unreadable. The thing that made this safe rather than frightening is that every commit is still reachable afterwards, so a mistake costs a lookup and not a day.

```sh
git fetch origin
git rebase origin/main
git reflog --date=iso | head -20
```

If a conflict turns out to be a mess, `git rebase --abort` puts everything back exactly as it was. The reflog line is the safety net: every pre-rebase tip is still listed there for ninety days, so nothing is ever actually lost.
