---
id: E5B26FB3-E700-45E1-805F-A4AA8A982074
created: 2026-06-06T11:00:00Z
modified: 2026-06-06T12:00:00Z
tags: [npm, ci]
golden: true
---
# What CI installs with

A build passed locally and failed in CI because the lockfile and the manifest disagreed, and one of the two silently resolved the difference in its own favour.

```sh
npm ci --no-audit --fund=false
```

`ci` deletes `node_modules` and installs exactly the lockfile, failing if it does not match the manifest. The two extra flags just stop it printing a wall of text.
