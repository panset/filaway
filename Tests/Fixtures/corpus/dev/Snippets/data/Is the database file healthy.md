---
id: 41982B1B-9B40-490F-97D8-D582EEB23A82
created: 2026-05-28T11:00:00Z
modified: 2026-05-28T12:00:00Z
tags: [sqlite]
golden: true
---
# Is the database file healthy

After a hard power loss mid-write, before trusting the derived index again. Both checks are cheap at this size and the file is disposable anyway.

```sh
sqlite3 filaway.sqlite 'pragma integrity_check; pragma foreign_key_check;'
```

The first walks the b-trees and prints `ok`; the second is the one that catches a chunk row pointing at a note that no longer exists. Both came back clean.
