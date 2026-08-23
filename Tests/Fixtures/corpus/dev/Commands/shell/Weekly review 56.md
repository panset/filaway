---
id: 583B618B-4610-4FB5-9008-FEFF306266B7
created: 2026-04-30T10:51:44Z
modified: 2026-05-19T10:51:44Z
---
# Weekly review 56

Someone asked about the container image in the channel and the answer was longer than it should be. Rebasing this branch was fine; it is the container image that made the review painful.

- [ ] ask the platform team about the container image
- [ ] reply to the thread about the container image

Logs from the deploy are useless here — nothing about the container image is written out at all. The container starts, the pod is ready, and the container image is still wrong.

- [ ] check whether the container image still needs the workaround
- [ ] book time to look at the container image properly

## Open questions

The staging environment lies about the container image, so measure on the real cluster.

