---
id: 8156919D-3703-40D2-97EB-7B42459E1B4C
created: 2026-06-05T11:00:00Z
modified: 2026-06-05T12:00:00Z
tags: [memory, swift]
golden: true
---
# The leak in the index build

Resident memory climbed steadily through a 5,000-note index build and never came back down, which for a batch job that runs at launch is the difference between a fine experience and a machine that starts swapping. Instruments needs Xcode, which this machine does not have, but the command-line tool reports at exit and that was enough.

```sh
leaks --atExit -- .build/debug/filaway-bench index --notes 200
```

It was not a leak: it was the vector matrix growing by doubling and never being sized down. The tool says "0 leaks for 0 total leaked bytes" and the footprint still grows, which is exactly the distinction between a leak and unbounded retention.
