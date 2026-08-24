---
id: 1C460EA7-50A8-4D04-923C-0F104FC1A207
created: 2026-06-23T11:00:00Z
modified: 2026-06-23T12:00:00Z
tags: [brew]
golden: true
---
# Pinning the postgres formula

An unrelated `brew upgrade` moved the local database a major version and every checkout's data directory stopped being readable. It is pinned now.

```sh
brew reinstall postgresql@16 && brew pin postgresql@16
```

A pinned formula is skipped by upgrade and says so. Unpin deliberately when the production version moves, not by accident on a Tuesday morning.
