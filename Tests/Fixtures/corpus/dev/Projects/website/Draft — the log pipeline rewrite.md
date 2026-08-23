---
id: 9CC04728-1852-4B2C-850F-018DCE239964
created: 2026-07-17T11:10:16Z
modified: 2026-07-24T11:10:16Z
---
# Draft — the log pipeline rewrite

Half of this is going to be wrong in a month, like everything about the log pipeline. There is a curl invocation somewhere in my history that would settle this about the log pipeline.

I keep meaning to write down how the log pipeline is actually wired, and keep not doing it. Someone asked about the log pipeline in the channel and the answer was longer than it should be.

I want a note that just holds the command, not an essay about the log pipeline. Rebasing this branch was fine; it is the log pipeline that made the review painful.

We agreed to revisit the log pipeline once the migration is finished, so probably never. The container starts, the pod is ready, and the log pipeline is still wrong.

- [ ] check whether the log pipeline still needs the workaround
- [ ] book time to look at the log pipeline properly

