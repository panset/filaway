---
id: E6C99EFE-25F1-474A-A354-AE0CBDEE0E16
created: 2026-04-29T11:00:00Z
modified: 2026-04-29T12:00:00Z
tags: [tcpdump]
golden: true
---
# Capturing the websocket handshake

The client reconnected in a loop and neither side logged a reason. With no useful log on either end, the only remaining source of truth is what actually went over the wire, captured to a file so it can be opened somewhere with a real protocol decoder.

```sh
sudo tcpdump -i any -s 0 -w ws.pcap 'tcp port 8443'
```

`-s 0` captures whole packets rather than the first 96 bytes, `-w` writes the raw capture instead of printing a summary. The upgrade request was being answered with a 301 by an intermediate proxy nobody knew was in the path.
