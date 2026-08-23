---
id: 56E77E93-80EF-4DBE-859D-4DBBC9E64FE6
created: 2026-05-23T11:00:00Z
modified: 2026-05-23T12:00:00Z
tags: [macos, linking]
golden: true
---
# What is this binary linking

The app launched on my machine and died instantly on a clean one, which is nearly always a link against something only a development install provides.

```sh
otool -L build/Filaway.app/Contents/MacOS/Filaway
```

Everything should resolve under `/usr/lib`, `/System` or `@rpath` inside the bundle. An absolute path into a Homebrew prefix is the bug.
