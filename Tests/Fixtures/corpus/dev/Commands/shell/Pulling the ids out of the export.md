---
id: E1C46A6A-44A3-4380-AF6A-1B8AB420E11C
created: 2026-08-15T11:00:00Z
modified: 2026-08-15T12:00:00Z
tags: [jq]
golden: true
---
# Pulling the ids out of the export

Support sent a 40 MB export and asked which records were still live. I only needed the identifiers of the active ones, one per line, so the next script could read them.

```sh
jq -r '.data.items[] | select(.status == "active") | .id' export.json > ids.txt
```

`-r` drops the quotes, which is the difference between a usable list and a file the next tool chokes on. 12,400 rows in, 3,180 out.
