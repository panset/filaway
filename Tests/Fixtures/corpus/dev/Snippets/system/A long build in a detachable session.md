---
id: 320677A8-181D-4CD7-9763-F56C1D8E1DFA
created: 2026-04-20T11:00:00Z
modified: 2026-04-20T12:00:00Z
tags: [tmux]
golden: true
---
# A long build in a detachable session

A release build outlives the ssh connection and I want to close the laptop halfway through, so it runs somewhere the terminal is not the thing keeping it alive.

```sh
tmux new-session -d -s build 'make release 2>&1 | tee build.log'
tmux attach -t build
```

`-d` starts it detached so the first command returns immediately; `tee` means the log survives even if the pane is closed. Ctrl-b d to detach again.
