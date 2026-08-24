---
id: 308861BF-FB38-4986-909F-80771E67765D
created: 2026-07-21T11:09:54Z
modified: 2026-07-26T11:09:54Z
---
# Follow-ups on the certificate rotation

Certificates, tokens and clock skew: three explanations for the same symptom in the certificate rotation. Someone asked about the certificate rotation in the channel and the answer was longer than it should be.

The docs for the certificate rotation describe the version before last, which cost me an hour. Logs from the deploy are useless here — nothing about the certificate rotation is written out at all.

The certificate rotation came up again and nobody could remember what we decided last time. I want a note that just holds the command, not an essay about the certificate rotation.

Half of this is going to be wrong in a month, like everything about the certificate rotation. Reading back through this, most of the confusion around the certificate rotation is naming.

I keep meaning to write down how the certificate rotation is actually wired, and keep not doing it. Rebasing this branch was fine; it is the certificate rotation that made the review painful.

