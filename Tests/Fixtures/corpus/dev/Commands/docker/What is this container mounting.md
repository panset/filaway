---
id: 3D560442-D8C1-415B-9F45-6E9BE31616FB
created: 2026-05-13T11:00:00Z
modified: 2026-05-13T12:00:00Z
tags: [docker]
golden: true
---
# What is this container mounting

A file the service writes was not showing up on the host, which usually means the volume is not mounted where the compose file claims it is.

```sh
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' filaway-api-1
```

The Go template beats piping the whole JSON blob through a parser when all you want is two fields. It was an anonymous volume shadowing the bind mount.
