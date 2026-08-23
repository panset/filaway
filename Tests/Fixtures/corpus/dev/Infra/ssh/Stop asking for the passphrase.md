---
id: B47832D7-1FA8-4E3F-B473-E9BFEED753C3
created: 2026-05-02T11:00:00Z
modified: 2026-05-02T12:00:00Z
tags: [ssh, macos]
golden: true
---
# Stop asking for the passphrase

Every new terminal wanted the key passphrase again, which after a reboot is thirty times a day. On macOS the agent can hand it to the Keychain and stop asking.

```sh
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

Add `UseKeychain yes` and `AddKeysToAgent yes` under `Host *` in `~/.ssh/config` to make it survive a reboot. The old spelling was `-K`, which still works but is deprecated.
