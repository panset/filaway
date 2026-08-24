---
id: 66D2C5A7-EE54-45F3-BC40-0ACE73F840E6
created: 2026-07-03T11:00:00Z
modified: 2026-07-03T12:00:00Z
tags: [ssh, postgres]
golden: true
---
# Tunnelling to the primary database

The database only accepts connections from inside the VPC and the only way in is the bastion. Rather than run a client on the jump host, the port comes to me.

```sh
ssh -N -L 55434:db-primary.internal:5432 -J jump@bastion.internal.example deploy@edge-01.internal.example
```

`-N` means "no remote command, just the forward". `-J` does the two-hop dance that used to need a ProxyCommand. Point the client at localhost:55434 and it looks local.
