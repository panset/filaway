---
id: 144010CD-BBE0-4969-A8B6-8960E05879CA
created: 2026-05-19T11:00:00Z
modified: 2026-05-19T12:00:00Z
tags: [ffmpeg]
golden: true
---
# Shrinking a video for chat

Screen captures come off this machine at about 8 MB a second, and the chat client rejects anything over 25 MB, so everything worth sharing has to be re-encoded first.

```sh
ffmpeg -i raw.mov -c:v libx264 -crf 28 -preset slow -c:a aac -b:a 96k small.mp4
```

CRF 28 with the slow preset is the sweet spot for screen content — text stays legible and a two-minute capture lands around 12 MB. Lower CRF is bigger and better.
