---
id: C926EAE8-33A7-4935-8DAC-BA2B6F3B7D75
created: 2026-06-10T11:00:00Z
modified: 2026-06-10T12:00:00Z
tags: [launchctl, macos]
golden: true
---
# Registering a login agent

The nightly reindex should start with the session and not need anyone to remember it. `launchctl load` is deprecated and silently does nothing on recent systems.

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tejaspanse.filaway.indexer.plist
launchctl print gui/$(id -u)/com.tejaspanse.filaway.indexer
```

`print` is how you find out why it is not running — the exit status and the last spawn time are both in there. Use `bootout` to remove it.
