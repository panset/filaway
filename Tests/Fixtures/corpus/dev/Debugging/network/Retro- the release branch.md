---
id: 81F5EC99-771A-45C3-9B3F-C79809C54FB4
created: 2026-05-29T11:35:32Z
modified: 2026-06-03T11:35:32Z
tags: [release-branch]
---
# Retro: the release branch

Reading back through this, most of the confusion around the release branch is naming. Logs from the deploy are useless here — nothing about the release branch is written out at all.

The staging environment lies about the release branch, so measure on the real cluster. Half of this is going to be wrong in a month, like everything about the release branch.

## Background

I want a note that just holds the command, not an essay about the release branch.

There is a curl invocation somewhere in my history that would settle this about the release branch. The tricky part with the release branch is that it only misbehaves when the machine is loaded.

## Decisions

Someone asked about the release branch in the channel and the answer was longer than it should be.

