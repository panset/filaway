---
id: 95243AD2-3D1E-41E9-9DA3-8ADE2C8BF148
created: 2026-03-26T10:40:11Z
modified: 2026-04-13T10:40:11Z
---
# the log pipeline — open questions

We agreed to revisit the log pipeline once the migration is finished, so probably never. I keep meaning to write down how the log pipeline is actually wired, and keep not doing it.

Half of this is going to be wrong in a month, like everything about the log pipeline. Rebasing this branch was fine; it is the log pipeline that made the review painful.

The log pipeline came up again and nobody could remember what we decided last time. The docs for the log pipeline describe the version before last, which cost me an hour.

Certificates, tokens and clock skew: three explanations for the same symptom in the log pipeline. I want a note that just holds the command, not an essay about the log pipeline.

