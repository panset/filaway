---
id: 67A7073F-EE23-4C97-A548-3B1E2FF66509
created: 2026-05-23T11:29:30Z
modified: 2026-05-28T11:29:30Z
---
# the gateway — open questions

There is a curl invocation somewhere in my history that would settle this about the gateway. The docs for the gateway describe the version before last, which cost me an hour.

The tricky part with the gateway is that it only misbehaves when the machine is loaded. We agreed to revisit the gateway once the migration is finished, so probably never.

- [ ] check whether the gateway still needs the workaround
- [ ] book time to look at the gateway properly

Rebasing this branch was fine; it is the gateway that made the review painful. The staging environment lies about the gateway, so measure on the real cluster.

We agreed to revisit the gateway once the migration is finished, so probably never. Worth benchmarking before touching the gateway; the last guess was off by an order of magnitude.

Worth benchmarking before touching the gateway; the last guess was off by an order of magnitude. The thing I actually needed was two directories up, filed under the gateway.

