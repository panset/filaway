---
id: A2263BE0-B4D9-4369-A7CF-21984404FDBA
created: 2026-07-01T11:27:48Z
modified: 2026-07-02T11:27:48Z
---
# Standup 219

Worth benchmarking before touching the certificate rotation; the last guess was off by an order of magnitude. The tricky part with the certificate rotation is that it only misbehaves when the machine is loaded.

Half of this is going to be wrong in a month, like everything about the certificate rotation. The staging environment lies about the certificate rotation, so measure on the real cluster.

Reading back through this, most of the confusion around the certificate rotation is naming. Every time the token expires I go looking for the same thing about the certificate rotation.

