---
id: AC8204C9-6724-414F-9B04-125C5C09CC48
created: 2026-07-20T11:00:00Z
modified: 2026-07-20T12:00:00Z
tags: [pnpm, monorepo]
golden: true
---
# Building one workspace package

A full workspace build is six minutes and I changed one leaf package. The filter syntax builds that package and everything it depends on, and nothing else.

```sh
pnpm --filter @filaway/web... build
```

The trailing `...` means "and its dependencies"; a leading `...` means "and everything that depends on it", which is the one to use before opening a pull request.
