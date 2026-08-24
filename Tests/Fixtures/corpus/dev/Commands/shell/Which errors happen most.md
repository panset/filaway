---
id: BE0185B7-58DD-4EF5-90A2-F81F4B145FFF
created: 2026-06-27T11:00:00Z
modified: 2026-06-27T12:00:00Z
tags: [logs]
golden: true
---
# Which errors happen most

A day of logs and no aggregation anywhere. Cutting the message out of each line and counting the duplicates gives the ranking in a second and a half.

```sh
grep -F 'ERROR' app.log | cut -d'|' -f4 | sort | uniq -c | sort -rn | head -20
```

`uniq -c` only collapses *adjacent* duplicates, which is why the first sort is not optional. One message was 80% of the total and had been ignored for weeks.
