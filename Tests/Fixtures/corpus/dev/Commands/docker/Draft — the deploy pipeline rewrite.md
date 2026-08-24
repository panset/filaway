---
id: 8ED75DA4-6AEE-4141-A7CF-0234B3A1624C
created: 2026-03-29T11:16:47Z
modified: 2026-04-12T11:16:47Z
---
# Draft — the deploy pipeline rewrite

Someone asked about the deploy pipeline in the channel and the answer was longer than it should be. Half of this is going to be wrong in a month, like everything about the deploy pipeline.

```sh
npm run lint
```

The staging environment lies about the deploy pipeline, so measure on the real cluster. I keep meaning to write down how the deploy pipeline is actually wired, and keep not doing it.

