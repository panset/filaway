---
id: 877BFBA7-B03B-45BC-9A15-C20B466D2D8C
created: 2026-03-30T11:00:00Z
modified: 2026-03-30T12:00:00Z
tags: [macos, gatekeeper]
golden: true
---
# Opening a downloaded binary

A helper tool downloaded from a release page refused to run — "cannot be opened because the developer cannot be verified" — because the download put a quarantine attribute on it that Gatekeeper checks before anything else.

```sh
xattr -d com.apple.quarantine ./tool
```

`xattr -l` first, to see what is actually attached. Doing this is deciding to trust the binary yourself, so it is a per-file decision and never a blanket one.
