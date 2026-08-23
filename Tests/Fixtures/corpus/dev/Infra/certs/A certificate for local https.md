---
id: 3E272886-D262-4B0E-BBFA-A35F68549378
created: 2026-06-13T11:00:00Z
modified: 2026-06-13T12:00:00Z
tags: [openssl, tls]
golden: true
---
# A certificate for local https

The service worker will not register over plain http, so the development server needs a certificate even though nothing about it is trusted by anyone.

```sh
openssl req -x509 -newkey rsa:2048 -nodes -keyout local.key -out local.crt -days 365 -subj '/CN=localhost'
```

`-nodes` leaves the key unencrypted so the server can start unattended. Add it to the login keychain and mark it trusted, or every request is an interstitial.
