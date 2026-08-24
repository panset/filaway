---
id: E5A939A7-626D-43B4-8467-76D2C79D4E4C
created: 2026-04-27T11:00:00Z
modified: 2026-04-27T12:00:00Z
tags: [python]
golden: true
---
# Serving a folder in the browser

The generated documentation uses fetch for its search index, which the browser refuses to do from a `file://` URL. It needs a real origin, and only for five minutes.

```sh
python3 -m http.server 8123 --bind 127.0.0.1 --directory ./out
```

Binding to loopback matters on a shared network — the default binds every interface and quietly publishes whatever directory you are standing in.
