---
id: 74C205FD-8B97-4B9C-8423-B709D0D8C2E1
created: 2026-05-07T11:00:00Z
modified: 2026-05-07T12:00:00Z
tags: [curl]
golden: true
---
# Where does this old link go

Auditing the redirect table after the docs move. I wanted the final status and the next hop and nothing else — no body, no progress bar, no headers dumped to the screen.

```sh
curl -sSIL -o /dev/null -w '%{http_code} %{redirect_url}\n' https://example.com/old-path
```

`-I` asks for HEAD, `-L` follows the chain, and `-w` prints exactly the two fields I care about. A 308 with an empty redirect target means the chain ended there.
