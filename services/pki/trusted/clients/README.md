# Pre-trusted client PKI certificates

Drop public `.crt` files here to pre-trust them. This directory is bind-mounted at
`/usr/local/bin/ignition/data/config/local/ignition/gateway-network/client/security/pki/trusted/certs/`
inside the container — the actual location Ignition 8.3 reads for GAN client trust.
Any certificate file present at first boot bypasses Ignition's cert-quarantine step
for outgoing GAN connections.

Typical contents:

- `engine-demo.chariot.io.crt` (or whatever the Hub's public cert is)
- One file per remote endpoint we connect to over TLS

These are **public** certificates — fine to commit to the repo. Never put private
keys (`*.key`, `*.pem` containing `BEGIN PRIVATE KEY`) here. The trust store
expects PEM-encoded X.509 certs only.

To extract a server's public cert for trust-on-first-use:

```bash
echo | openssl s_client -connect engine-demo.chariot.io:8060 -servername engine-demo.chariot.io 2>/dev/null \
  | openssl x509 -outform PEM > engine-demo.chariot.io.crt
```

Inspect what you got:

```bash
openssl x509 -in engine-demo.chariot.io.crt -noout -subject -issuer -dates
```

Files placed here load on the **first** boot of a fresh gateway DB. To re-seed
trust on an already-initialized gateway, either:

1. `docker compose down -v` then redeploy (destructive — wipes the gateway DB), or
2. Use the gateway web UI's certificate management to import additional trust
   at runtime.
