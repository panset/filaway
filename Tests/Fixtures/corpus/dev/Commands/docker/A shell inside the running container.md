---
id: DC6C7740-74EB-474B-BEC0-82353AF31406
created: 2026-07-10T11:00:00Z
modified: 2026-07-10T12:00:00Z
tags: [docker]
golden: true
---
# A shell inside the running container

The config the service is actually using did not match the config in the repo, and the only way to settle it was to look at the filesystem the process sees.

```sh
docker exec -it filaway-api-1 /bin/bash
```

Alpine-based images have no bash — use `/bin/sh` there. `-it` is what gives you a usable terminal rather than a hung, echo-less prompt.
