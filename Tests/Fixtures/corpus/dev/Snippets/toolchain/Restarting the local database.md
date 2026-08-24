---
id: 191947B0-5FED-475F-B74F-46C57ABB425A
created: 2026-05-15T11:00:00Z
modified: 2026-05-15T12:00:00Z
tags: [brew, postgres]
golden: true
---
# Restarting the local database

After changing `max_connections` the setting did not take, because the service had been running since the last reboot and never re-read its configuration file.

```sh
brew services restart postgresql@16 && brew services list
```

The listing at the end is the useful half — it shows whether the service came back or went straight to `error`, which a bare restart hides.
