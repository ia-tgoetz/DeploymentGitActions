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

**For runtime module install in 8.3, use a DIRECT bind mount to `external-modules` plus the unattended-install JVM flags. Named-volume-with-bind interferes with the first-boot module scan even when pointed at the same host path.**

Auto-installing the Cirrus Link MQTT Transmission `.modl` failed under two patterns before working:

1. `/usr/local/bin/ignition/user-lib/modules/` (bind mount, no flags) — IA's docs describe this as the path for "built-in" modules, but in our 8.3.6 setup nothing loaded from here on first boot.

2. `/usr/local/bin/ignition/external-modules/` mounted via a **named volume with `driver: local`, `o: bind`, `device: services/modules`** — same JVM flags as below. Still didn't trigger install. The named-volume layer between Docker and the host path apparently breaks Ignition's first-boot scan or watch.

The pattern that **does** work is from IA's `module-dev-ignition` example (Adam Koch, IA SE):

```yaml
volumes:
  - ./services/modules:/usr/local/bin/ignition/external-modules   # DIRECT bind, not named-volume-with-bind

command: >
  -n <name>
  --
  -Dignition.allowunsignedmodules=true
  -Dignition.modules.install.unattended=true
  -Dignition.modules.install.trust-unknown-certificates=true
  -Dignition.gateway.externalModulesFolder=/usr/local/bin/ignition/external-modules
```

Plus EULA env vars matching the actual module ID:

```yaml
GATEWAY_MODULES_ACCEPTED: "com.cirruslink.mqtt.transmission"
ACCEPT_MODULE_LICENSES:   "com.cirruslink.mqtt.transmission"
ACCEPT_MODULE_CERTS:      "com.cirruslink.mqtt.transmission"
```

**Key takeaway:** for `external-modules`, the bind mount must be a direct `host_path:container_path` entry. Don't use the `driver_opts: type: none, o: bind, device: <path>` named-volume pattern that works fine for `services/projects/` and `services/config/resources/`. Whatever Ignition does to scan that directory at boot is sensitive to the mount type, not just the destination path.

**Behavior to expect:** Ignition consumes the `.modl` from the mounted directory during install (the host file may disappear after first boot). `fetch-modules.sh` re-downloads on the next deploy if needed; named volumes survive container restarts so re-install only happens on a clean DB.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**Always extract the module ID from `module.xml` inside the `.modl` itself. Don't assume it matches the display name, the resource-folder path, or the file name. Sometimes a suffix that looks like a path component (e.g. `.gateway`) IS part of the canonical ID; sometimes it isn't. Only the manifest is authoritative.**

For Cirrus Link MQTT Transmission 5.0.3, all three of these strings appear in different contexts and look interchangeable, but they're not:

| Source | Value | Is it the module ID? |
|---|---|---|
| Gateway UI display name | `MQTT Transmission` | No |
| `data/config/resources/core/<dir>/` resource folder | `com.cirruslink.mqtt.transmission.gateway` | **Yes — happens to match the manifest in this case** |
| `module.xml` `<id>` element | `com.cirruslink.mqtt.transmission.gateway` | **Yes — authoritative** |

The `.gateway` suffix here IS part of the canonical module ID — even though it looks like a path component for the gateway-scope resource folder. This is the kind of thing you can only know by reading the manifest. Other modules may have different conventions.

**Always extract from `module.xml`:**

```bash
# From the host (Linux/macOS, Python is everywhere)
python3 -c "import zipfile; print(zipfile.ZipFile('path/to/Module-signed.modl').read('module.xml').decode())"
```

```powershell
# Windows
Expand-Archive .\Module-signed.modl -DestinationPath .\inspect
Select-String -Path .\inspect\module.xml -Pattern '<id>|<name>|<requiredignitionversion>|<depends'
```

```bash
# From inside the running container
docker exec <container> python3 -c "import zipfile; print(zipfile.ZipFile('/usr/local/bin/ignition/external-modules/Module-signed.modl').read('module.xml').decode())"
```

Look for `<id>`, `<name>`, `<requiredignitionversion>`, and especially `<depends scope=...>` — the dependency block tells you what other modules must be loaded for this one to install.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**Cirrus Link MQTT Transmission 5.0.3 declares a hard dependency on `com.inductiveautomation.eventstream`. Event Streams isn't available on Ignition Edge, so MQTT Transmission 5.0.3 cannot install on Edge.**

The manifest:

```xml
<depends scope="DG">com.inductiveautomation.eventstream</depends>
```

`scope="DG"` means the dependency is required for both **D**esigner and **G**ateway scopes. With the dependency unsatisfied, Ignition's module manager silently skips the install — no log entry, no install attempt. The only downstream symptom is a `W [g.TagProviderManagerImpl]: Unable to update Managed Tag Provider 'MQTT Transmission'` warning if there's pre-staged config that references the missing module.

**For an Edge deployment, do NOT use MQTT Transmission 5.0.3.** Use either:

- An older Cirrus Link version that pre-dates the Event Streams dependency (likely 4.0.x — verify by extracting `module.xml` from each candidate before staging).
- A future version that drops or makes the dependency optional (check Cirrus Link's release notes).

Diagnostic: gateway shows the module is supposed to be there (e.g. via warning about its tag provider), the `.modl` is in the bind-mounted external-modules folder, all install JVM flags are set correctly, but no `Loading module` / `Started module` messages ever appear → check the manifest's `<depends>` block. Mismatch between dependency and the running edition is the most likely cause.

---

### Optimization Strategy: 2026-05-08 (seeded manually)

**For fleet-deployed Edge IPCs, bake third-party modules into a derived Docker image at build time. Push to GHCR. IPCs pull. Drop the runtime module mount entirely.**

After exhausting the runtime-mount approaches (external-modules + install JVM flags, user-lib/modules + bind mount), the working pattern in this environment is:

1. `build/edgeGwBuild/Dockerfile` — `FROM inductiveautomation/ignition:8.3.6` + `COPY *.modl /usr/local/bin/ignition/user-lib/modules/`. Build once locally:
   ```bash
   docker build -t edge-with-transmission:8.3.6 --build-arg IGNITION_VERSION=8.3.6 ./build/edgeGwBuild
   ```
2. `scripts/push-image-to-ghcr.sh` — push (or `docker load` from a tar then push) to `ghcr.io/<owner>/ignition-edge:<tag>`.
3. `docker-compose.yml` — `image: ghcr.io/<owner>/ignition-edge:8.3.6`. No bind mount for modules. Drop install-flow JVM flags. Keep `ACCEPT_MODULE_LICENSES` and `ACCEPT_MODULE_CERTS` for the modules baked in.
4. **First-time GHCR access setup:** the new package needs visibility set to private and the deployment repo added to "Manage Actions access" with Read role, otherwise the workflow's `GITHUB_TOKEN` 403s on pull.

Why this is the right pattern at scale:

- **Predictable steady state.** Every IPC pulls the same image. No per-host fetch step, no per-host mount path.
- **Modules are versioned with the image.** `ignition-edge:8.3.6-mqtt-5.0.3` makes module changes explicit in the image tag and trivial to roll back.
- **Module-version changes are an explicit operator action**, not an automatic thing that might happen mid-deploy.
- **Bandwidth at fleet scale.** Docker layer caching means upgrade pulls are tiny (just the changed layers), where a per-IPC `fetch-modules` would re-download the full `.modl` to every site.

When *not* to use this: dev/staging where you're iterating on which modules to include — the runtime-mount approach is faster to iterate on. But for production, bake.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**`GATEWAY_ADMIN_USERNAME` and `GATEWAY_ADMIN_PASSWORD` env vars are honored ONLY on the first boot of a fresh gateway DB. Changing them after init is a no-op — rotate via the web UI or wipe the named volume.**

If a gateway entered an init-loop failure mode (e.g. the `-h`/`-s`-without-`-a` restart loop) before completing DB init, the named volume can end up in a partially-written state where the DB exists but no admin user does. Subsequent successful boots load that DB and ignore the env-var credentials, leaving the gateway with no working login.

Fix: `docker compose down -v` to wipe the named volume entirely, then redeploy. The env-var credentials apply on the next boot because the DB is genuinely fresh.

For ongoing password rotation in a healthy deployment, change it through the gateway UI (or the gateway-network API) rather than by re-deploying with new secrets.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**Private GHCR packages need explicit repo access. A workflow's auto-injected `GITHUB_TOKEN` cannot pull from a private package by default if the package was created by an out-of-band push (e.g. a manual `mirror-to-ghcr.sh` from a workstation), even if the package is owned by the same user as the repo.**

Symptom from `docker pull`:

```
Error response from daemon: error from registry: unauthorized
unexpected status from HEAD request to https://ghcr.io/v2/<owner>/<image>/manifests/<tag>: 403 Forbidden
```

Fix is in the GHCR package settings, not in code:

1. <https://github.com/users/{owner}/packages/container/{name}/settings>
2. Scroll to **"Manage Actions access"** (or **"Manage repository access"**)
3. **Add Repository** → select the deployment repo → role **Read** (or Write if the workflow pushes)
4. Optionally, link the package permanently to the repo under **"Linked repository"**

When a workflow pushes to GHCR, the package is auto-linked to that repo. When you push from a workstation with a personal PAT, the package is owned by the user but has no repo association — every workflow that wants to pull it must be granted access explicitly.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**`usermod -aG docker <user>` does not affect a running systemd service. Stop and start the service for the new group to take effect.**

Workflow symptom:

```
Run docker info
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
Error: Process completed with exit code 1.
```

This appears after `provision-runner.sh` has already added the runner user to the docker group, because:

1. `usermod -aG docker github-runner` modifies `/etc/group` and updates the user's group list for **future** logins/processes.
2. Existing processes (including the systemd-managed runner) still hold the old group set in their PID's credentials.
3. Restarting the systemd service spawns a fresh PID with refreshed groups.

Fix on the IPC:

```bash
cd ~/actions-runner   # or /opt/actions-runner — svc.sh requires CWD inside the runner dir
sudo ./svc.sh stop
sudo ./svc.sh start
sudo ./svc.sh status
```

`newgrp docker` only affects the current shell, not running daemons. The provisioning script handles this correctly when run end-to-end, but if `usermod` is run after the service is already up, a stop/start is required.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**`./svc.sh: command not found` means `config.sh` hasn't been run yet — `svc.sh` is generated, not extracted.**

GitHub's "New self-hosted runner" page lists download → extract → `config.sh` → `svc.sh install`. The runner tarball does NOT contain `svc.sh` at the top level after extraction. `config.sh` registers the runner with GitHub and writes out `svc.sh` (and a few other files) at that point.

If `ls ~/actions-runner` shows `config.sh`, `run.sh`, `bin/`, `externals/`, etc. but no `svc.sh`, it means step b (the `config.sh` invocation) was skipped. Run `config.sh --url <repo> --token <one-time-token> --unattended --replace --name <name>` first.

Related paste-time gotcha: the snippet GitHub provides includes a `shasum -a 256 -c <hash>  actions-runner-...tar.gz` line followed by `# Extract the installer`. If pasted as one line, the `#` is consumed by `shasum` as `-c#`, errors out with `Unknown option: #`, and the rest of the line ("Extract the installer") is treated as further args. Harmless — the next line's `tar xzf` still runs — but confusing on first read. Either ignore the error or put the comment on its own line.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**On Ubuntu 23.04+ (PEP 668), `pip install` to system Python fails with "externally-managed-environment". Use a venv inside the workflow step.**

When a workflow step needs to install Python deps (e.g. the troubleshooting agent's `anthropic` package), do not run `pip install -r requirements.txt` directly. Modern Debian/Ubuntu mark the system Python as externally-managed and `pip` refuses to write into it. The error is:

```
error: externally-managed-environment
× This environment is externally managed
```

`--break-system-packages` works but is bad hygiene. Cleanest path is a one-shot venv per step:

```yaml
- name: Run agent
  run: |
    python3 -m venv /tmp/agent-venv
    /tmp/agent-venv/bin/pip install --quiet -r scripts/requirements.txt
    /tmp/agent-venv/bin/python scripts/deploy_agent.py
```

`provision-runner.sh` installs `python3`, `python3-venv`, and `python3-pip` so the venv path is guaranteed to exist on every runner.

---

### Troubleshooting Rule: 2026-05-07 (seeded manually)

**First boot of a fresh Ignition gateway with module auto-install can take 5+ minutes. Don't set the health-check timeout below 10 minutes for first boots.**

Cold-boot timing for our 8.3.6 Edge stack on a 4 vCPU / 8 GB Proxmox VM:

- Container start → init.sh → init.properties: ~5 s
- Wrapper bootstrap → JVM start: ~30 s
- Internal DB initialization (fresh volume only): 60–120 s
- Module install pass (Cirrus Link MQTT Transmission): 30–90 s additional
- Gateway hits `RUNNING`: typically 2–4 min, occasionally 5+ min on slower hardware

The original `health-check.sh` polled for 5 minutes (30 × 10 s) and produced false failures on first boot. Bumped to 10 minutes (60 × 10 s) by default; tunable via `HEALTH_MAX_RETRIES` and `HEALTH_INTERVAL` env vars. Subsequent boots are 30–60 s — the long wait is only on a clean named volume.

**Diagnostic tell:** if `curl /StatusPing` returns connection refused for the first 90 s and "RUNNING" after, the health check is fine — the gateway is just booting. If it returns connection refused for >5 minutes with no progress in `docker logs`, something is genuinely broken (init loop, OOM, port conflict).

---

### Optimization Strategy: 2026-05-07 (seeded manually)

**Workflow that auto-commits to its own repo must use `paths-ignore` on the trigger to avoid an infinite deploy loop. `[skip ci]` in the commit message alone does NOT block GitHub Actions.**

The deploy workflow grants `contents: write` so the troubleshooting agent can push memory updates. Without protection, every memory commit would trigger another deploy run, which would either re-trigger the agent or no-op — but in either case waste a runner minute and pollute history.

`[skip ci]` is a Travis/GitLab/CircleCI convention. **GitHub Actions does not honor `[skip ci]` natively.** The reliable mechanism is `paths-ignore` on the workflow trigger:

```yaml
on:
  push:
    branches: [main]
    paths-ignore:
      - 'scripts/memory.md'
```

A push that ONLY changes `scripts/memory.md` is excluded from the trigger and no run starts. Mixed pushes (memory + other files) still trigger normally. Belt-and-suspenders: also include `[skip ci]` in the auto-commit message for visual clarity in the git log, even though it's not load-bearing.

Without this guard the failure mode is: agent records lesson → workflow auto-commits and pushes → push triggers new deploy → if it fails, agent records another lesson → loop. `paths-ignore` is the only thing that breaks the cycle.

---
