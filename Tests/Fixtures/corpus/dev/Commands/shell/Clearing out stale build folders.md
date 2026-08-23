---
id: DBE798D9-ED06-408B-A8E0-F261D02B89AB
created: 2026-05-21T11:00:00Z
modified: 2026-05-21T12:00:00Z
tags: [find]
golden: true
---
# Clearing out stale build folders

Twenty checkouts on this disk, each with a build directory of a gigabyte or so, most of them untouched since spring.

```sh
find . -type d -name .build -mtime +30 -print0 | xargs -0 rm -rf
```

The null separator is what makes this safe with paths that contain spaces. Run it once with `-print` alone before adding the delete.
