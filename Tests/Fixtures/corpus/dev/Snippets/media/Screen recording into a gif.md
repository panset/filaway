---
id: 940D462D-DE13-475D-A182-CE77DE3E651B
created: 2026-07-26T11:00:00Z
modified: 2026-07-26T12:00:00Z
tags: [ffmpeg]
golden: true
---
# Screen recording into a gif

The README wanted a six-second loop of the search panel. QuickTime records a 40 MB .mov; the readme needs something under two megabytes that plays inline on GitHub.

```sh
ffmpeg -ss 00:00:04 -t 6 -i demo.mov -vf 'fps=12,scale=720:-1:flags=lanczos' -loop 0 demo.gif
```

Twelve frames a second is the point where a UI recording still reads as motion; the `-1` keeps the aspect ratio. Put `-ss` before `-i` so the seek is fast.
