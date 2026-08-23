---
id: 2824F587-5637-4C46-9E3A-3F3BB8FEACA9
created: 2026-06-27T10:00:55Z
modified: 2026-07-12T10:00:55Z
---
# Thinking about the deploy pipeline

Reading back through this, most of the confusion around the deploy pipeline is naming. Someone asked about the deploy pipeline in the channel and the answer was longer than it should be.

The thing I actually needed was two directories up, filed under the deploy pipeline. The docs for the deploy pipeline describe the version before last, which cost me an hour.

Rebasing this branch was fine; it is the deploy pipeline that made the review painful. Half of this is going to be wrong in a month, like everything about the deploy pipeline.

I keep meaning to write down how the deploy pipeline is actually wired, and keep not doing it. I want a note that just holds the command, not an essay about the deploy pipeline.

- [ ] check whether the deploy pipeline still needs the workaround
- [ ] write up what changed in the deploy pipeline

Logs from the deploy are useless here — nothing about the deploy pipeline is written out at all. The staging environment lies about the deploy pipeline, so measure on the real cluster.

