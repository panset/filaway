---
id: D46B8959-9283-4852-8BE7-E52E427019D2
created: 2026-06-24T11:00:00Z
modified: 2026-06-24T12:00:00Z
tags: [docker]
golden: true
---
# Reclaiming the disk docker ate

Forty gigabytes gone and the build failing with no space left. Most of it was dangling build layers and volumes from throwaway database containers that were never cleaned up.

```sh
docker system prune -af --volumes
docker builder prune --filter 'until=168h'
```

`--volumes` is the flag that actually frees the bulk, and the flag that will delete data you meant to keep — check `docker volume ls` first if anything local matters.
