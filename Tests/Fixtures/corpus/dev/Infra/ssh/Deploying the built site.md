---
id: 5DC46CB0-F75E-43EC-B831-F4F5918FCF06
created: 2026-07-29T11:00:00Z
modified: 2026-07-29T12:00:00Z
tags: [rsync, deploy]
golden: true
---
# Deploying the built site

The static bundle goes to the edge box directly while the pipeline is still being rebuilt. Only changed files cross the wire, and anything on the far side that is no longer in the build is removed.

```sh
rsync -avz --delete --exclude '.build' ./dist/ deploy@edge-01.internal.example:/srv/filaway/
```

The trailing slash on the source is load-bearing: without it rsync creates a `dist` directory inside the destination instead of copying its contents. `--delete` with a wrong path is how you erase a server, so it always runs with `-n` first.
