---
id: E0E3C79A-BFAF-4744-85ED-340BC7659F4C
created: 2026-05-09T11:54:05Z
modified: 2026-05-19T11:54:05Z
---
# Idea: a better the search panel

I keep meaning to write down how the search panel is actually wired, and keep not doing it. Logs from the deploy are useless here — nothing about the search panel is written out at all.

## Open questions

There is a curl invocation somewhere in my history that would settle this about the search panel.

The docs for the search panel describe the version before last, which cost me an hour. The tricky part with the search panel is that it only misbehaves when the machine is loaded.

```sh
docker compose ps
```

