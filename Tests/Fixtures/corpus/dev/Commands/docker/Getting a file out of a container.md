---
id: 0637408A-7911-4374-9330-B1D61E06A302
created: 2026-06-03T11:00:00Z
modified: 2026-06-03T12:00:00Z
tags: [docker]
golden: true
---
# Getting a file out of a container

The crash log only exists inside the container and the container is about to be recycled by the restart policy, so it needs to be on my machine before that happens.

```sh
docker cp filaway-api-1:/var/log/app/error.log ./error.log
```

Works in both directions and works on a stopped container too, which matters when the thing you want to examine is why it stopped.
