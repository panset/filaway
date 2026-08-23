---
id: 35707CB4-40D2-49F3-818F-EB9C3AE988E7
created: 2026-07-04T11:00:00Z
modified: 2026-07-04T12:00:00Z
tags: [curl, webhooks]
golden: true
---
# Replaying a webhook event

A customer's event was dropped when the receiver restarted. I saved the payload the provider had logged and pushed it back through by hand rather than asking them to resend, which would have re-run their whole retry schedule.

```sh
curl -sS -X POST -H 'Content-Type: application/json' \
  --data-binary @webhook-payload.json https://hooks.internal.example/v1/events
```

`--data-binary` rather than `-d`: plain `-d` strips newlines, and the signature is computed over the exact bytes, so a stripped payload fails verification every time.
