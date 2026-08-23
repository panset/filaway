---
id: 5F3920E3-4FE0-4303-AC6F-236E824B3192
created: 2026-06-09T11:46:39Z
modified: 2026-06-18T11:46:39Z
---
# Questions for the platform team 153

I keep meaning to write down how the log pipeline is actually wired, and keep not doing it. Logs from the deploy are useless here — nothing about the log pipeline is written out at all.

I want a note that just holds the command, not an essay about the log pipeline. We agreed to revisit the log pipeline once the migration is finished, so probably never.

- [ ] reply to the thread about the log pipeline
- [ ] reply to the thread about the log pipeline

Half of this is going to be wrong in a month, like everything about the log pipeline. The staging environment lies about the log pipeline, so measure on the real cluster.

The docs for the log pipeline describe the version before last, which cost me an hour. The tricky part with the log pipeline is that it only misbehaves when the machine is loaded.

