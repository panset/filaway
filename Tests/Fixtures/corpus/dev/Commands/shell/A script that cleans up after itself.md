---
id: 4BD4F5DC-33A0-498A-AC6F-F8DD4DE06183
created: 2026-04-24T11:00:00Z
modified: 2026-04-24T12:00:00Z
tags: [bash]
golden: true
---
# A script that cleans up after itself

The release script left half a gigabyte of scratch directories behind every time it failed, which was often, because it also carried on happily after a failed step.

```bash
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
```

The trap fires on a normal exit, an error and a Ctrl-C alike. `set -euo pipefail` is the other half: without it a failing step in the middle of a pipeline is invisible.
