---
id: 979D490D-639D-491B-AA48-DC94E03CD371
created: 2026-04-11T11:00:00Z
modified: 2026-04-11T12:00:00Z
tags: [bash, secrets]
golden: true
---
# A key as one long line

The deployment target wants the signing key as a single-line environment variable, and a stray newline in the middle produces an error message that says nothing useful.

```sh
base64 -i secret.pem | tr -d '\n' | pbcopy
```

macOS `base64` wraps at 76 columns unless you strip them; GNU coreutils wants `-w 0` instead. Never let this land in shell history — it is on the clipboard, then gone.
