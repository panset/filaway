---
id: B7DB836A-051E-46DB-A861-9C86C2F828D5
created: 2026-07-12T11:00:00Z
modified: 2026-07-12T12:00:00Z
tags: [python]
golden: true
---
# A fresh python environment

The conversion scripts need their own interpreter state; installing them globally is how the last machine ended up with three incompatible versions of one library.

```sh
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
```

`.venv` is gitignored and rebuilt in a minute, so it is never worth backing up. `deactivate` when done, or just close the terminal.
