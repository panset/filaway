---
id: DAD17B5F-0DFF-40A4-B26B-D2D62077DB08
created: 2026-04-15T11:00:00Z
modified: 2026-04-15T12:00:00Z
tags: [bash, testing]
golden: true
---
# Catching a flaky test

One suite fails perhaps one run in thirty and only on a loaded machine, which makes it impossible to study — by the time you notice, the output has scrolled away.

```sh
until ! swift test --filter ChurnTests; do :; done
```

Loops while the command keeps succeeding and stops the moment it fails, leaving the failing output on screen. Took eleven minutes and forty-one runs to reproduce.
