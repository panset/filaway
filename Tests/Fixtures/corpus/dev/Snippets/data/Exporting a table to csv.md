---
id: D9FB0246-120E-4BEB-987B-E1B9D92A66BC
created: 2026-07-06T11:00:00Z
modified: 2026-07-06T12:00:00Z
tags: [sqlite]
golden: true
---
# Exporting a table to csv

Wanted the note table in a spreadsheet to eyeball the modification dates against what the sidebar was showing, with a header row so the columns mean something.

```sh
sqlite3 -header -csv filaway.sqlite "select id, relpath, mtime from notes order by mtime desc;" > notes.csv
```

The flags have to come before the filename. `mtime` is seconds since the epoch, so the spreadsheet needs a formula to turn it into a date.
