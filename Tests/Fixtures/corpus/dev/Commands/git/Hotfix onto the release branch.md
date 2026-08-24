---
id: 37764BC4-B417-44A4-B2EE-4A6159FC587B
created: 2026-08-01T11:00:00Z
modified: 2026-08-01T12:00:00Z
tags: [git, release]
golden: true
---
# Hotfix onto the release branch

The null-check fix landed on main, but 1.4 is cut and only takes fixes. One commit, copied across, with a reference back to where it came from so the release notes can be generated later.

```sh
git cherry-pick -x 4c9e02f
git push origin release/1.4
```

The `-x` appends "(cherry picked from commit …)" to the message. Without it, working out months later whether a fix is on both branches means diffing trees.
