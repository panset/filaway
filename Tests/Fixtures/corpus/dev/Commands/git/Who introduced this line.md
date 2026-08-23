---
id: 70E29062-4251-45B1-9E44-CEABEA28E8F7
created: 2026-05-17T11:00:00Z
modified: 2026-05-17T12:00:00Z
tags: [git]
golden: true
---
# Who introduced this line

Trying to work out why the recency multiplier is capped where it is. The comment says nothing useful, so the answer is in the commit that introduced the constant, not in the file as it stands.

```sh
git log -S 'recencyPrior' --oneline -- Sources/FilawayCore/Search
git blame -L 120,160 Sources/FilawayCore/Search/HybridSearch.swift
```

`-S` searches for commits that changed the *number of occurrences* of a string, which finds the introduction rather than every commit that touched the file.
