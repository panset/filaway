---
id: 3751BEE6-5EF3-46BD-8911-C7B1DDF89052
created: 2026-07-27T11:00:00Z
modified: 2026-07-27T12:00:00Z
tags: [docker, postgres]
golden: true
---
# A throwaway postgres for tests

The integration suite wants a real database, not a fake, but nothing about it should survive the run or collide with the one brew is already running on 5432.

```sh
docker run --rm -d --name pgtest -e POSTGRES_PASSWORD=devonly -p 55432:5432 postgres:16
```

`--rm` removes the container when it stops, so nothing accumulates. The password is deliberately worthless — this container is never reachable off the machine.
