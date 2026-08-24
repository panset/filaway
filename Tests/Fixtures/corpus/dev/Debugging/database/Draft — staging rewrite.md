---
id: 1499A26B-545C-465A-ACB0-CBE3EC6938AB
created: 2026-03-03T10:41:47Z
modified: 2026-03-12T10:41:47Z
---
# Draft — staging rewrite

The staging environment lies about staging, so measure on the real cluster. The thing I actually needed was two directories up, filed under staging.

The tricky part with staging is that it only misbehaves when the machine is loaded. Certificates, tokens and clock skew: three explanations for the same symptom in staging.

- [ ] write up what changed in staging
- [ ] reply to the thread about staging

We agreed to revisit staging once the migration is finished, so probably never. The tricky part with staging is that it only misbehaves when the machine is loaded.

## Leftovers

Worth benchmarking before touching staging; the last guess was off by an order of magnitude.

```sh
open build/Filaway.app
```

