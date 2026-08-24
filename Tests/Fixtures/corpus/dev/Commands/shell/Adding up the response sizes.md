---
id: 046FFC4E-D374-436E-892C-918043BF8B00
created: 2026-06-18T11:00:00Z
modified: 2026-06-18T12:00:00Z
tags: [awk, logs]
golden: true
---
# Adding up the response sizes

The egress bill jumped and I wanted to know how much of it was successful responses before going anywhere near the provider's console.

```sh
awk '$9 == 200 { total += $10 } END { printf "%.1f MB\n", total/1048576 }' access.log
```

Field nine is the status and ten is the byte count in the combined log format. Two gigabytes a day, almost all of it one uncached endpoint.
