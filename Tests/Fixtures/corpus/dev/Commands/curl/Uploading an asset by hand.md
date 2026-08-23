---
id: 8BCDE63C-B51A-4C90-B42F-6055FCDBFC55
created: 2026-06-20T11:00:00Z
modified: 2026-06-20T12:00:00Z
tags: [curl]
golden: true
---
# Uploading an asset by hand

The web uploader was broken during the release freeze, so the cover images went up from the terminal. Multipart, one field for the file and one for the kind.

```sh
curl -sS -X POST -H "Authorization: Bearer $ASSET_TOKEN" \
  -F "file=@cover.png" -F "kind=thumbnail" https://assets.internal.example/v1/upload
```

The `@` is what makes it read the file rather than send the literal name. Anything over 8 MB is rejected by the edge before the service sees it.
