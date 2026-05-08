# Agent Deployment Memory

This file is appended to by the Claude DevOps Agent (`scripts/deploy_agent.py`) when a deployment fails and it identifies a novel, generalizable lesson. Entries below are auto-generated.

> ⚠️ Do not put credentials, hostnames, IPs, or PII in this file — it is public.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**Ignition `-h` / `-s` / `-a` CLI flags must be passed as a complete trio, or not at all.**

The Ignition Docker image's gateway entrypoint accepts `-h <http-port>`, `-s <https-port>`, and `-a <public-address>` to configure the gateway's **public-facing web address** (used in download links, Gateway Network self-identification, redirects). These flags are interdependent — supplying any one of them without the other two causes the init container to fail in a tight restart loop with:

```
ERROR: Gateway Public HTTP/HTTPS/Address must be specified together:
  - Address not specified
```

The container will burn CPU restarting indefinitely; the gateway never opens port 8088, so the health check times out with no diagnostic clue from `curl /StatusPing` (you only see "not ready" retries until you read the actual `docker logs`).

**These flags do NOT set the internal listener ports.** The container listens on 8088 (HTTP) and 8043 (HTTPS) by default; `ports:` in docker-compose maps them to the host. Public-address flags are only needed if the gateway sits behind a reverse proxy / load balancer / public DNS and needs to advertise a different URL than the request arrived on.

**For an Edge IPC accessed by IP directly: omit all three.** Public address auto-derives from the inbound request URL.

**For a reverse-proxied gateway:** pass all three together — e.g. `-h 80 -s 443 -a gateway.example.com`.

**Diagnostic tell:** if `docker logs <gateway>` shows the same `Parsed systemName / Parsed httpPort / Creating init.properties / ERROR: Address not specified` cycle repeating once per minute (with exponential backoff that stretches to ~60s gaps), it's this misconfiguration — not a slow boot.

---
