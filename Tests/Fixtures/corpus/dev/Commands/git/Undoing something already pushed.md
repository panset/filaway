---
id: A8EE5974-3205-4984-8A13-071ABE1F19B6
created: 2026-04-30T11:00:00Z
modified: 2026-04-30T12:00:00Z
tags: [git]
golden: true
---
# Undoing something already pushed

A commit went to main that should not have. Rewriting shared history would have broken everyone's checkout, so the fix is a new commit that undoes the old one.

```sh
git revert --no-edit 7a31c9d
```

Reverting a merge needs `-m 1` to say which parent is the mainline. For an ordinary commit this is all it takes, and the history stays honest about what happened.
