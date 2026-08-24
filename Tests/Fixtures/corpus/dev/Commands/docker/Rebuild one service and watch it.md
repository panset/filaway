---
id: 5167E65A-E5FA-4C9C-A6F7-F790B68B3527
created: 2026-08-12T11:00:00Z
modified: 2026-08-12T12:00:00Z
tags: [docker]
golden: true
---
# Rebuild one service and watch it

Iterating on the API container. Bringing the whole stack down and up again takes two minutes; rebuilding the single service that changed and then following its output takes fifteen seconds and shows me the stack trace immediately.

```sh
docker compose up -d --build api && docker compose logs -f --tail=100 api
```

`--tail=100` so the scrollback starts with the boot sequence rather than replaying the whole day. Ctrl-C stops following without stopping the container.
