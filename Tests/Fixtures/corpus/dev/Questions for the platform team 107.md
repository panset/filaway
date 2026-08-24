---
id: 15012613-9189-4993-BB9F-242919DC8F08
created: 2026-05-17T10:16:02Z
modified: 2026-05-31T10:16:02Z
tags: [deploy-pipeline]
---
# Questions for the platform team 107

I keep meaning to write down how the deploy pipeline is actually wired, and keep not doing it. The container starts, the pod is ready, and the deploy pipeline is still wrong.

The staging environment lies about the deploy pipeline, so measure on the real cluster. The docs for the deploy pipeline describe the version before last, which cost me an hour.

## What I tried

I want a note that just holds the command, not an essay about the deploy pipeline.

