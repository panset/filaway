---
id: 3159EFD3-7F97-4C55-AE37-74561CB07E84
created: 2026-04-08T11:00:00Z
modified: 2026-04-08T12:00:00Z
tags: [ssh]
golden: true
---
# Sessions that stop dropping

Every idle session died after a few minutes behind the office NAT, usually in the middle of a long-running command. Keeping a trickle of traffic on the connection stops the NAT deciding it is finished with it.

```conf
Host *.internal.example
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

Client-side, so it works regardless of what the server allows. Six missed probes at thirty seconds means a genuinely dead link is still noticed within three minutes.
