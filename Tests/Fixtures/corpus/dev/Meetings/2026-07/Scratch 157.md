---
id: 24CA3245-6A35-45FA-8C25-AEAE42C0ED14
created: 2026-04-28T11:02:18Z
modified: 2026-05-04T11:02:18Z
tags: [container-image]
---
# Scratch 157

There is a curl invocation somewhere in my history that would settle this about the container image. Logs from the deploy are useless here — nothing about the container image is written out at all.

I want a note that just holds the command, not an essay about the container image. I keep meaning to write down how the container image is actually wired, and keep not doing it.

```sh
tail -n 50 build.log
```

The tricky part with the container image is that it only misbehaves when the machine is loaded. We agreed to revisit the container image once the migration is finished, so probably never.

There is a curl invocation somewhere in my history that would settle this about the container image. The docs for the container image describe the version before last, which cost me an hour.

- [ ] write up what changed in the container image
- [ ] check whether the container image still needs the workaround

