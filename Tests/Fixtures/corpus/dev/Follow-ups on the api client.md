---
id: 022331D7-54A7-449C-BC69-A319E1EA47CE
created: 2026-08-14T11:24:01Z
modified: 2026-08-15T11:24:01Z
---
# Follow-ups on the api client

Rebasing this branch was fine; it is the api client that made the review painful. Logs from the deploy are useless here — nothing about the api client is written out at all.

There is a curl invocation somewhere in my history that would settle this about the api client. Someone asked about the api client in the channel and the answer was longer than it should be.

The container starts, the pod is ready, and the api client is still wrong. Reading back through this, most of the confusion around the api client is naming.

The staging environment lies about the api client, so measure on the real cluster. The tricky part with the api client is that it only misbehaves when the machine is loaded.

We agreed to revisit the api client once the migration is finished, so probably never. The thing I actually needed was two directories up, filed under the api client.

I keep meaning to write down how the api client is actually wired, and keep not doing it. The thing I actually needed was two directories up, filed under the api client.

