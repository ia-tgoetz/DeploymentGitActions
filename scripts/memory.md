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

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**For runtime module install in 8.3, use the external-modules pattern, not user-lib/modules.**

We tried two paths for auto-installing the Cirrus Link MQTT Transmission `.modl`:

1. `/usr/local/bin/ignition/user-lib/modules/` (bind mount, no JVM flags) — IA's docs describe this as the path for "built-in" modules. **In our 8.3.6 setup, modules dropped here did not load on first boot.** Whether this is an Edge-specific quirk, a load-order issue, or a docs mismatch is unclear, but multiple deploy attempts with a fresh DB and correctly-set EULA env vars never produced a Loaded module.

2. `/usr/local/bin/ignition/external-modules/` (bind mount) plus JVM flags:
   ```
   -Dignition.modules.install.unattended=true
   -Dignition.modules.install.trust-unknown-certificates=true
   -Dignition.gateway.externalModulesFolder=/usr/local/bin/ignition/external-modules
   ```
   This is the pattern from IA's `module-dev-ignition` example (Adam Koch, IA SE). Despite originating in a developer demo, it's what actually triggers auto-install of pre-staged signed modules in our 8.3.6 deployment.

**Behavior to expect:** Ignition consumes the `.modl` from the mounted directory during install (it gets moved into the gateway's internal modules store). The host file may disappear after first boot. `fetch-modules.sh` re-downloads on the next deploy if needed; named volumes survive container restarts so re-install only happens on a clean DB.

The `user-lib/modules/` path is documented in IA's docs but did not work standalone in our environment. The external-modules + JVM flag combination did.

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**`GATEWAY_MODULES_ACCEPTED` (and the License/Certs siblings) is a case-insensitive SUBSTRING match against the module's internal name. Always include the module's DISPLAY name; the resource-folder package ID alone may not match.**

Set `GATEWAY_MODULES_ACCEPTED=com.cirruslink.mqtt.transmission.gateway` (the resource-folder ID for Cirrus Link MQTT Transmission). The module appeared in `services/modules/` but did not auto-install — Ignition's internal check looks at the module's display name (`MQTT Transmission`), and the resource-folder ID is not a substring of it.

Fix: include both forms, comma-separated.

```yaml
GATEWAY_MODULES_ACCEPTED: "MQTT Transmission,com.cirruslink.mqtt.transmission.gateway"
ACCEPT_MODULE_LICENSES: "MQTT Transmission,com.cirruslink.mqtt.transmission.gateway"
ACCEPT_MODULE_CERTS:    "MQTT Transmission,com.cirruslink.mqtt.transmission.gateway"
```

Whichever string Ignition matches against, one of them hits. **When adding a new third-party module, always include both the display name and the resource-folder ID in these env vars.**

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**`GATEWAY_ADMIN_USERNAME` and `GATEWAY_ADMIN_PASSWORD` env vars are honored ONLY on the first boot of a fresh gateway DB. Changing them after init is a no-op — rotate via the web UI or wipe the named volume.**

If a gateway entered an init-loop failure mode (e.g. the `-h`/`-s`-without-`-a` restart loop) before completing DB init, the named volume can end up in a partially-written state where the DB exists but no admin user does. Subsequent successful boots load that DB and ignore the env-var credentials, leaving the gateway with no working login.

Fix: `docker compose down -v` to wipe the named volume entirely, then redeploy. The env-var credentials apply on the next boot because the DB is genuinely fresh.

For ongoing password rotation in a healthy deployment, change it through the gateway UI (or the gateway-network API) rather than by re-deploying with new secrets.

---
