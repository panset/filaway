---
id: 231EF37D-5011-46AF-AA05-521B87CF866E
created: 2026-04-06T11:00:00Z
modified: 2026-04-06T12:00:00Z
tags: [jq, macos]
golden: true
---
# Tidying json on the clipboard

Someone pastes a single-line blob into chat and the only question is what shape it is. Round-tripping it through the clipboard keeps it out of a file I would then forget to delete.

```sh
pbpaste | jq . | pbcopy
```

`jq .` alone re-indents and sorts nothing; add `-S` when diffing two payloads, because key order is otherwise whatever the server felt like.
