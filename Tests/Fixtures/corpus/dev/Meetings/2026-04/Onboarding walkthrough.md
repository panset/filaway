---
id: 2B1E0A82-1710-47B3-AC20-9EC2A52D2858
created: 2026-04-18T11:00:00Z
modified: 2026-04-18T12:00:00Z
tags: [meeting, setup]
golden: true
---
# Onboarding walkthrough

Ran the new starter through a machine setup. Everything after the toolchain is one command, which is the point of the bootstrap target — the environment file is decrypted by direnv and the make target resolves dependencies and checks the optional tools.

```sh
git clone git@github.com:acme/filaway.git && cd filaway && direnv allow && make setup
```

Two things to fix in the guide: the ssh key has to be on the account before the clone, and `direnv allow` fails with a confusing message if the hook is not in the shell rc.
