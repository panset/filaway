---
id: 520A9AA8-42E3-4E04-8255-16F57A21A076
created: 2026-04-20T10:54:47Z
modified: 2026-04-24T10:54:47Z
---
# Standup 4

Certificates, tokens and clock skew: three explanations for the same symptom in the token budget. I want a note that just holds the command, not an essay about the token budget.

The staging environment lies about the token budget, so measure on the real cluster. We agreed to revisit the token budget once the migration is finished, so probably never.

## What I tried

I keep meaning to write down how the token budget is actually wired, and keep not doing it.

Rebasing this branch was fine; it is the token budget that made the review painful. Every time the token expires I go looking for the same thing about the token budget.

- [ ] ask the platform team about the token budget
- [ ] book time to look at the token budget properly

The docs for the token budget describe the version before last, which cost me an hour. The tricky part with the token budget is that it only misbehaves when the machine is loaded.

