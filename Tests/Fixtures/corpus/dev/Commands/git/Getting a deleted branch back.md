---
id: 007B6F2D-FF85-4CDF-B078-8E341FB2F9F7
created: 2026-06-29T11:00:00Z
modified: 2026-06-29T12:00:00Z
tags: [git]
golden: true
---
# Getting a deleted branch back

I pruned merged branches with a script that was a little too enthusiastic and took a branch that had never been merged with it. The commits were still there; only the name was gone, and the name is the cheap part to restore.

```sh
git reflog --all | grep -i 'checkout: moving from feature/answer-card'
git branch feature/answer-card 9f2c1ab
```

Find the last SHA the branch pointed at in the reflog, then point a fresh branch at it. Garbage collection would eventually have taken them, which is why this is a same-day fix and not a next-month one.
