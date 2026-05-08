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

### Troubleshooting Rule: 2026-05-07 (seeded manually, revised 2026-05-08)

**Runtime module installation on Ignition Edge 8.3 is brittle. Bake third-party modules into a derived image at build time instead — that's the supported and predictable path.**

We exhausted multiple runtime patterns trying to get Cirrus Link MQTT Transmission to install on Edge before settling on image-baking:

1. `/usr/local/bin/ignition/user-lib/modules/` mounted via named-volume + `o:bind`, no JVM flags — module appeared in Config → Modules but state was `default`, never loaded.
2. `/usr/local/bin/ignition/external-modules/` via named-volume + `o:bind` plus the `module-dev-ignition` JVM flag combo (`unattended`, `trust-unknown-certificates`, `externalModulesFolder`) — silent skip, no install attempt logged.
3. Same as (2) but with a **direct** bind mount (`./services/modules:/usr/local/bin/ignition/external-modules`) — still failed, but for a different reason (gateway DB cached an old catalog entry from prior attempts).
4. **Image-baking** — `Dockerfile` extends `inductiveautomation/ignition:8.3.6` and `COPY`s `*.modl` into `/usr/local/bin/ignition/user-lib/modules/`, image is pushed to GHCR, IPC pulls. **This works.**

The image-baking path is what's wired up now (`build/edgeGwBuild/Dockerfile`, `.github/workflows/build-image.yml`, `run-build-edge.{sh,ps1}` for local builds). Modules in `user-lib/modules/` of the IMAGE (not a runtime mount) are loaded by Ignition at boot without going through the install pipeline that does signature/dependency validation. EULA env vars (`ACCEPT_MODULE_LICENSES`, `ACCEPT_MODULE_CERTS`) still apply for the modules baked in.

**Key takeaways:**

- **For Edge fleet deployment, image-bake.** Don't try to drop `.modl` into a runtime mount and hope Ignition installs it. The behavior is inconsistent across versions and edition tiers.
- **The various install-pipeline JVM flags** (`-Dignition.modules.install.unattended=true`, etc.) are from IA's `module-dev-ignition` developer demo. They're for iterating on modules being built, not for production deployment of signed third-party modules.
- **Named-volume-with-bind has weirdness.** It works fine for `services/projects/` and `services/config/resources/` but appears to interfere with module-folder scans. We never fully root-caused this; once we moved to image-baking the question became moot.

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

### Troubleshooting Rule: 2026-05-08 (revised — earlier draft was wrong)

**`<depends>` declarations in `module.xml` are checked by the install pipeline, not the load pipeline. Modules baked into `user-lib/modules/` are loaded directly and bypass the dependency check.**

Cirrus Link MQTT Transmission 5.0.3 has this in its manifest:

```xml
<depends scope="DG">com.inductiveautomation.eventstream</depends>
```

Event Streams is a Standard-edition module not available on Edge. We initially concluded this meant 5.0.3 simply couldn't run on Edge — and **that was wrong**. The dependency check fires only when Ignition's module install pipeline processes a `.modl` (the pathway you hit when you drop a file into the external-modules folder, or when an admin uploads via the web UI). Modules pre-staged in `user-lib/modules/` of the image are loaded by the runtime directly without going through that install validation.

**Result: 5.0.3 runs fine on Edge when image-baked**, despite the manifest's `<depends>` declaration. The transmitter publishes to MQTT, all the gateway-scope features work. Whatever EventStream-dependent code paths exist in 5.0.3's Designer-scope DG bundle simply aren't exercised on Edge (there's no Designer attaching to it anyway).

Implications:

- **Don't pre-emptively rule out a module on Edge based on a `<depends>` in the manifest.** Bake it in and see what loads. If the gateway-scope code paths the module exercises don't actually need the missing dep, it just works.
- **The diagnostic pattern earlier (silent skip, no Loading message)** was the install pipeline rejecting the module. That's a different code path from runtime load-from-user-lib. Same outcome (module not running), different cause.
- **For runtime install attempts that fail silently:** `<depends>` is one cause among several (DB cache poisoning, runtime-mount path quirks). Check `<depends>` AFTER ruling out volume state.

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

### Troubleshooting Rule: 2026-05-08 (seeded manually)

**Module-version upgrades require wiping the data volume on the IPC. The image's `user-lib/modules/` is the SOURCE; once Ignition extracts it on first boot, the running module lives in `/data/modules/` (the named volume) and that copy shadows future image updates.**

After we successfully image-baked Cirrus Link 5.0.3, the gateway showed 5.0.0 in Config → Modules. The `.modl` in the running image was 5.0.3, but Ignition was loading from `/data/modules/` which had been seeded from a prior install attempt with 5.0.0.

The upgrade flow that actually rolls a new module version is:

1. Update `build/edgeGwBuild/modules.txt` (or the local `.modl` file) to the new version
2. CI rebuilds and republishes `ghcr.io/<owner>/ignition-edge:<version>` (or run `run-build-edge` + `run-push-edge` locally)
3. **On each IPC**, `docker compose down -v` to wipe the data volume — this is the part that's easy to forget
4. Trigger a deploy → fresh DB, fresh extraction from `user-lib/modules/`, new version loads

Without step 3, IPCs keep running the cached old version even though they pulled the new image. The image is correct; the runtime is just loading from a stale source.

Diagnostic confirmation: extract `module.xml` from the live container's `user-lib/modules/*.modl` and compare to the `version` field shown in the gateway UI — if they disagree, you're hitting the cache-shadowing pattern.

**`docker compose down -v` is destructive — it wipes the gateway DB.** That's fine for Edge IPCs where the DB content is reproducible from `services/config/resources/` (file-based VCS config) and `services/projects/`, but never run `down -v` on a gateway whose DB holds state you can't recreate (manually-configured GAN connections, custom user accounts, runtime-only tag values).

For a multi-IPC fleet, this becomes a sequenced rolling upgrade rather than a `git push`. Worth wrapping in a script or runbook.

---

### Troubleshooting Rule: 2026-05-08 (seeded manually)

**Windows PowerShell 5.1 (the default `powershell.exe` on Windows 10 / 11) doesn't reliably handle UTF-8 source files without a BOM. Keep `.ps1` scripts ASCII-only.**

Symptom: a `.ps1` that parses fine on PowerShell 7 dies on 5.1 with errors like:

```
Missing closing '}' in statement block or type definition.
```

…pointing at code that visually has matched braces.

Root cause: any non-ASCII character (em dash `—`, en dash `–`, smart quotes `"` `'`, ellipsis `…`) in the script is decoded as Windows-1252 instead of UTF-8 when the file lacks a BOM. The mis-decoded bytes shift the tokenizer's view of subsequent characters, producing seemingly nonsensical brace errors several lines downstream from the actual offending byte.

Fix: replace non-ASCII output strings with ASCII (`-` for em dash, `"` for smart quotes). No special tooling needed; just don't paste from word processors / docs that auto-substitute.

This bites our `run-*.ps1` wrappers because the `Write` tool that generated them outputs plain UTF-8. PowerShell 7+ handles it; 5.1 doesn't. Until the user base is on 7+, all PowerShell scripts in this repo should be ASCII-only and use Allman-style brace placement (`}\nelse {` not `} else {`) to avoid further parser confusion if any non-ASCII slips in.

---

### Optimization Strategy: 2026-05-08 (seeded manually)

**For per-IPC values that need to land in a tracked config file at deploy time, use a deploy-time rewrite script. Don't try to make the file dynamic in git.**

`services/config/resources/.../transmitter/<name>/config.json` has an `edgeNodeId` field that should be unique per IPC (the Cirrus Link broker identifies edge gateways via the `groupId/edgeNodeId/deviceId` triple). Three approaches considered:

1. **Per-IPC branch.** Each IPC pulls its own branch with its own committed `config.json`. Heavy maintenance burden, doesn't scale.
2. **Placeholder + envsubst.** File has `__HOSTNAME__` in git; deploy script substitutes. Simple but the file in git no longer parses as JSON, and IDE tooling (jq, json-schema validators) chokes.
3. **Deploy-time rewrite.** File in git has a placeholder *value* (`"edgeNodeId": "Edgenode93"`); deploy script uses `jq` to overwrite `.edgeNodeId` to the IPC's hostname before `docker compose up`.

We chose (3). Implementation: `scripts/configure-transmitter.sh` walks every transmitter `config.json`, sets `.edgeNodeId` to `${IGN_NAME:-$(hostname)}`. Wired into `deploy.yml` between `Write runtime .env` and `Restart Ignition Edge`.

Properties of this pattern:

- **Git file always parses as valid JSON** — no placeholder values, no template syntax. IDE tooling works.
- **Idempotent.** Running the script twice produces the same result. Re-deploys reset the file to the committed state via `actions/checkout`, then re-apply the dynamic value — no drift.
- **Generalizable.** Same pattern works for any field that needs a per-IPC value. Add a new entry in the rewrite script; the file in git just holds a default/example value.

When NOT to use this: secrets (those should never live in a file at all — use env vars from Secrets), or values that change at runtime after deploy (those should use Ignition's own config-mode mechanism). For "deploy-time, per-IPC, from a non-secret source like hostname", this is the right shape.

---

### Optimization Strategy: 2026-05-08 (seeded manually)

**For Gateway Network outgoing connections that need TLS, pair `GATEWAY_NETWORK_<idx>_*` env vars with a pre-staged `.crt` in the PKI trust store. Both are first-boot-only mechanisms; together they eliminate the manual cert-quarantine approval step.**

Two complementary pieces in `docker-compose.yml`:

```yaml
environment:
  GATEWAY_NETWORK_0_HOST: engine-demo.chariot.io
  GATEWAY_NETWORK_0_PORT: 8060
  GATEWAY_NETWORK_0_PINGRATE: 1000
  GATEWAY_NETWORK_0_ENABLESSL: true
  GATEWAY_NETWORK_0_ENABLED: true
volumes:
  - ./services/pki/trusted/clients:/usr/local/bin/ignition/data/config/local/ignition/gateway-network/client/security/pki/trusted/certs
```

How it works:

- The `GATEWAY_NETWORK_<idx>_*` env vars are read by IA's image entrypoint on the first DB-init. They seed an outgoing GAN connection in `config.idb`. Subsequent boots ignore the env vars (DB is the source of truth from then on).
- The bind mount overlays just the GAN-client trust store at `data/config/local/ignition/gateway-network/client/security/pki/trusted/certs/`. **The path is non-obvious** — IA's PKI trust isn't a single flat tree, it's namespaced per-feature (gateway-network, opcua, etc.) under `data/config/local/<feature>/security/pki/trusted/`. Earlier `data/pki/trusted/clients/` was a guess that turned out wrong; verify the path against the running gateway's filesystem if you ever doubt it.

Why both are required: enabling SSL on the GAN connection without pre-trusting the cert means Ignition flags the connection as `Quarantined` on first attempt, and an admin has to approve the cert via the web UI before traffic flows. Pre-trusting flips it to `Connected` immediately on first boot. For a fleet of headless IPCs, the manual approval step would be a per-site human bottleneck.

Extracting a remote's public cert for trust-on-first-use:

```bash
echo | openssl s_client -connect <host>:<port> -servername <host> 2>/dev/null \
  | openssl x509 -outform PEM > services/pki/trusted/clients/<host>.crt
```

Constraints to remember:

- Both mechanisms are first-boot-only. Re-seeding either one requires `docker compose down -v` (destructive — wipes the gateway DB).
- `services/pki/trusted/clients/` only contains **public** certs. Never put private keys or PEMs containing private material there.
- For multiple GAN connections, increment the index: `GATEWAY_NETWORK_1_*`, `GATEWAY_NETWORK_2_*`, etc.

For runtime adjustments to an already-running gateway (post-first-boot), the alternatives are: use the gateway web UI's GAN config page, or call the REST API directly (`scripts/configure-gan.sh` shows the shape).

---

### Optimization Strategy: 2026-05-08 (seeded manually, revised after PDF check)

**For Edge fleets, override Ignition's per-gateway auto-generated metro keystore with a single shared fleet identity keystore at the conventional path. The Hub admin approves one cert; the entire fleet is trusted from then on.**

Authoritative source for the configuration shape: IA's *Setting Up Your Own Gateway Network Certificate* (kept under the repo root). The doc walks through the full CSR-to-CA workflow; for our self-signed fleet model, the CSR step is replaced by `openssl req -x509 -addext subjectAltName=...` in one shot.

The actual configuration is much simpler than I had it before — Ignition reads the keystore from a fixed path with a fixed alias, controlled by a single JVM property:

| Concern | Value |
|---|---|
| Keystore file in the image | `/usr/local/bin/ignition/webserver/metro-keystore` (conventional; Ignition reads it on boot if present) |
| Format | PKCS12 (or JKS — PKCS12 is fine for modern Java) |
| Alias inside the keystore | `metro-key` (fixed by Ignition convention) |
| JVM property to unlock | `-Dmetro.keystore.password=<password>` (the only flag) |
| Default password to avoid | `metro` (5 chars, rejected by modern keytool — must be ≥ 6 chars) |

Earlier in this project I attempted this with `-Dgateway.metroKeystorePath`, `-Dgateway.metroKeystoreType`, `-Dgateway.metroKeystoreAlias`, and `-Dgateway.metroKeystorePassword`. **None of those four properties exist in Ignition.** They were a hallucination; the actual setting is just `metro.keystore.password` (and the file path / alias are not configurable — Ignition reads them by convention). Don't reach for "set the keystore path via JVM arg" — it's not a thing. Replace the file at the conventional path instead.

The fleet-cert pattern collapses N approvals into 1:

1. **Generate one self-signed cert + private key with multi-SAN** (`scripts/generate-fleet-cert.{ps1,sh}`). The bash version reads `config/fleet.txt` and emits a `DNS:` SAN per hostname; takes a `FLEET_IPS=...` env var for IP SANs. The PowerShell version does DNS SANs only (Windows native APIs make IP-typed SANs awkward — use the bash version on Linux/WSL if you need IP coverage).
2. **Bake the keystore into the image** at `/usr/local/bin/ignition/webserver/metro-keystore`. Note the path is **outside** `/data/` — Ignition's `webserver/` is part of the image, not the data volume, so the named volume can't shadow it.
3. **Set `-Dmetro.keystore.password=<password>`** in `docker-compose.yml`'s command. Default is `changeit` (matches `generate-fleet-cert`).
4. **Hub admin trusts `fleet-cert.crt` once.** Every Edge identifies under that cert from then on.

Distribution paths for the keystore:

- **Local build:** the file lives at `build/edgeGwBuild/metro-keystore` on the workstation. The Dockerfile picks it up via a conditional `RUN` (so its absence isn't an error). The image is private (GHCR), so the keystore travels inside it to IPCs.
- **CI build:** base64-encode the file and store as a `FLEET_KEYSTORE_BASE64` repo Secret. The Build Edge Image workflow decodes it into the build context as `metro-keystore` before `docker build`. Keeps the private key out of the repo and out of operator-workstation drift.

SAN strategy — wildcards:

- X.509 has no syntactic wildcard for arbitrary IP ranges, and `dns:edge-*` (without a parent domain) isn't valid wildcard SAN syntax — `*` is only valid as the leftmost label of a real domain (`*.fleet.example.com`).
- Practical workarounds: enumerate hostnames/IPs explicitly in the SAN (what `generate-fleet-cert.sh` does, reading `config/fleet.txt`), use a parent-domain wildcard if your IPCs share one, or skip SAN entirely if the Hub doesn't enforce hostname/IP verification.
- Regenerate the keystore + redistribute when the fleet grows. There's no automation around that yet — it's a deliberate operator action.

Constraints / trade-offs:

- **The keystore contains the private key.** Anyone with image-pull access (or repo Secret access on the CI path) effectively has the fleet's TLS identity.
- **No zero-downtime cert rotation.** Regenerate → redistribute → rolling-redeploy. Brief overlap window where Hub sees both old and new certs is unavoidable — keep both trusted at the Hub during cutover, or take the maintenance.
- **All Edges identify as the same TLS endpoint.** Per-IPC visibility on the Hub side is reduced (the gateway names still differ, but the cert subject is the same for every Edge). For per-IPC TLS identity with single Hub-side trust action, set up your own CA and sign per-IPC certs — different pattern, more operational complexity.

The conditional Dockerfile pattern (`if [ -f /tmp/build-ctx/metro-keystore ]; then cp ...; fi`) is what lets the same Dockerfile work in both modes: with the fleet keystore for production fleets, without it for dev / testing / single-IPC scenarios. Strict glob `COPY` would 1-or-fail at build time; the conditional tolerates either input.

When NOT to use this: very small deployments (1-2 IPCs) where per-IPC manual approval is fine, compliance regimes that mandate per-device unique TLS identity, or any scenario where a single-fleet-cert compromise can't be tolerated.

---

### Optimization Strategy: 2026-05-08 (seeded manually)

**Lock fleet-deployed Edges to outbound-only GAN with mutual TLS. Combine `allowIncoming=false` with `requireSSL=true` + `requireTwoWayAuth=true` + `securityPolicy=ApprovedOnly` for defense-in-depth.**

The settings file `services/config/resources/core/ignition/gateway-network-settings/config.json` is a file-based VCS resource that's loaded on every boot (no first-boot-only quirks like the env-var seeding). For Edges that should never serve as connection targets — i.e., everything in a hub-and-spoke fleet — the right config is:

```json
{
  "allowIncoming": false,
  "requireSSL": true,
  "requireTwoWayAuth": true,
  "securityPolicy": "ApprovedOnly"
}
```

What each one does:

- **`allowIncoming: false`** — Edge doesn't open a listening GAN port. The container still maps `8060` to the host (compose's `ports:` block), but Ignition won't accept anything on it. Belt-and-suspenders with firewall rules: even if a network mistake exposes 8060, no GAN session can establish.
- **`requireSSL: true`** — Forbids unencrypted GAN. Important even on "trusted" internal networks, because lateral movement makes plaintext exploitable.
- **`requireTwoWayAuth: true`** — Both sides present and validate certs during the GAN handshake. The Edge's identity comes from the metro keystore (the fleet keystore, if you're using Option B); the Hub's identity comes from its own GAN cert (which the Edge trusts via the pre-staged `.crt`).
- **`securityPolicy: ApprovedOnly`** — Even if `allowIncoming` were flipped on later, only explicitly-approved certs would be honored. Useful as a guardrail against config drift.

The combination matters more than any individual setting. `allowIncoming=false` alone wouldn't help if a misconfigured deployment turned it on and accepted a self-signed cert under the default `Unrestricted` policy. `requireSSL=true` alone wouldn't help against a compromised cert. The four together close the surface from every angle.

Why this is in a file-based VCS resource (not env vars or JVM args): unlike `GATEWAY_NETWORK_<idx>_*` (first-boot-only) or `gateway.metroKeystore*` (JVM args, every boot but invisible to operators reviewing the running config), the GAN-settings JSON is the **canonical record** Ignition reads each boot. Operators can audit it via a `cat` on the IPC's bind-mounted file, and changes flow through git-controlled deploys rather than ephemeral env vars.

When NOT to use this posture: a topology where the Edge needs to serve GAN connections (rare for actual Edge IPCs — that's more common for site Edges acting as collector hubs in their own right). In that case, flip `allowIncoming` to `true` and add the originator's cert to `services/pki/trusted/clients/`. Keep `securityPolicy=ApprovedOnly` and the rest as-is.

---

### Optimization Strategy: 2026-05-08 (seeded manually)

**Fleet deploys with `runs-on: self-hosted` send each workflow run to ONE random runner from the labelled pool. To fan out to every IPC, give each runner a unique label (its hostname) and use a matrix strategy that targets `[self-hosted, <hostname>]` per matrix entry.**

The naive setup — N self-hosted runners all sharing labels `self-hosted,Linux,X64,ipc` — looks like it would distribute work to all of them, but it doesn't. GitHub Actions assigns a queued job to whichever runner in the matching label set is idle and picks it up first; the other runners stay Idle. So a `git push` triggers a deploy on exactly ONE IPC, not all of them.

The working pattern in this repo:

1. **Per-IPC label.** `provision-runner.sh` registers each runner with `self-hosted,Linux,X64,ipc,$(hostname)`. The hostname-as-label is what lets the workflow target a specific IPC.
2. **Tracked fleet roster.** `config/fleet.txt` lists every IPC by hostname, one per line, with `#` comments. Adding an IPC means appending its hostname and pushing — the next deploy picks it up.
3. **Two-phase workflow.** A `discover` job runs on `ubuntu-latest`, parses `fleet.txt` (or a `workflow_dispatch.inputs.ipc` override), and emits a JSON array as a job output. The `deploy` job consumes that output via `matrix.ipc` and uses `runs-on: [self-hosted, "${{ matrix.ipc }}"]` — that label combination resolves to exactly one runner.
4. **`fail-fast: false`** on the matrix so a bad IPC doesn't cancel deploys to the rest of the fleet.

Why this design over alternatives:

- **Tracked file vs runners API:** the GitHub API can list runners, but querying it from the workflow needs a PAT with admin scope (added Secret + ongoing rotation). A plain text file in the repo is the source of truth, version-controlled, and trivially diffable. Trade-off: provisioning a new IPC is a two-step gate (provision + add to fleet.txt). That's actually a feature — it prevents a half-provisioned IPC from being pulled into deploys.
- **Hostname as label vs explicit per-IPC labels (`region-east-01`):** hostname is already the gateway name and the runner name. Reusing it as the label keeps everything aligned — debugging "which IPC failed" is just looking at the matrix entry. Custom labels would let you target groups (e.g. `runs-on: [self-hosted, region-east]`), but you can do that via separate workflows or matrix filters when the fleet warrants it.
- **Matrix vs N separate workflows:** matrix gives one workflow run with N jobs, which is one entry in the Actions UI and one set of audit logs. N workflows is N runs to monitor — operationally noisier.

Race condition to know about: the `Commit agent memory if changed` step runs per matrix job. If two IPCs both fail and both agents append a lesson, both jobs try to push to `main` concurrently — the second one's push gets rejected (non-fast-forward). Fix is `git pull --rebase` retry-with-backoff on push failure (5 attempts, ~1-5s sleep each). Without the retry, the second lesson silently doesn't land.

When NOT to use the matrix pattern:
- **Single-IPC deployments.** The matrix overhead (discover job, JSON parsing, output passing) is wasted complexity if there's only ever one runner.
- **Sequenced rolling deploys.** `fail-fast: false` runs all matrix jobs in parallel. For "deploy to canary first, then everyone else", split into two jobs with `needs:` between them, or use a manual `workflow_dispatch.inputs.ipc` for the canary and an automatic push trigger for the full fleet (current setup supports both).
- **Heterogeneous fleet.** If different IPC classes need different deploy steps (e.g. some sites have extra modules), the matrix strategy gets unwieldy. Use job-level conditions or split into multiple workflows keyed off labels (`runs-on: [self-hosted, region-east]`).

For 5000+ IPC fleets the matrix approach hits GitHub's per-job concurrency limits and the `fleet.txt` file becomes a merge-conflict hotspot. At that scale, swap the static file for a runtime API call against your runner registry, batch deploys into smaller chunks (e.g., 50 at a time), and consider a job orchestrator outside Actions entirely. But for tens to low hundreds of IPCs, this pattern works.

---

### Troubleshooting Rule: 2026-05-08 (seeded manually)

**Ubuntu Server's installer allocates only ~50% of the disk to the root LV by default. Every fresh VM provisioned from a stock Ubuntu / Proxmox template needs `lvextend` + `resize2fs` to use the disk it was actually given.**

Symptom: an Ignition Edge container fails first-boot init with:

```
The Ignition Gateway has failed to successfully start.
Reason: java.nio.file.FileSystemException: /usr/local/bin/ignition/data/var/ignition/designer:
  No space left on device.
```

Or any of the equivalent "no space" complaints from the JVM, the Wrapper, or `apt-get`. `df -h /` shows 100% used; `du -sh /var/lib/docker` shows Docker is innocently small (a couple of GB out of a 15 GB filesystem).

The disk math doesn't add up because **the OS isn't seeing the full disk**. Ubuntu Server with the default LVM layout takes the smaller of (4 GB, half the disk) for the root LV at install time. The rest stays as `VFree` in the volume group, waiting for someone to run `lvextend`. On a 30 GB Proxmox VM disk, that means a 15 GB root filesystem and 15 GB of unused VG space — and Ignition's install footprint plus a fresh data volume happily fills 15 GB.

Diagnostic:

```bash
lsblk                              # shows the physical disk size — say 30G
sudo vgs                           # VFree column reveals the unallocated chunk
sudo lvs                           # LSize confirms how much the LV actually has
df -h /                            # what the kernel/userspace see
```

If `vgs` reports `VFree > 0`, the disk allocation is the problem (not the deploy pipeline, not the image, not Docker). Fix:

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /                            # confirm — root FS now matches disk size
```

No reboot needed; ext4 supports online resize. After that, the previously-failed deploy can be retriggered and Ignition's first-boot init has room to extract its modules and write its DB.

The fix becomes part of provisioning, not just troubleshooting. Two ways to bake it in:

1. **In the Proxmox template build:** run `lvextend` + `resize2fs` once at template-creation time, then snapshot. Every VM cloned from the template starts with a full-size root LV. This is the right place — provisioning scripts shouldn't have to repeat infrastructure decisions.
2. **As an early step in `provision-runner.sh`:** detect `VFree > 0` and run the resize automatically. Simpler if you don't control the template, but adds a moving part to a script that should be a no-op on already-correctly-provisioned hosts.

For the 5000-site Chevron fleet target, fix this in the template. Per-host resize commands at 5000-site scale is a script-and-pray pattern; the template should produce VMs that are correct on first boot.

When this is NOT the issue: if `vgs` shows `VFree 0` and `df -h /` still reports 100% used, the disk really is full — clean up apt cache (`apt-get clean`), journald (`journalctl --vacuum-size=200M`), or expand the underlying VM disk in Proxmox itself.

---

### Troubleshooting Rule: 2026-05-08 (seeded manually)

**When a self-hosted runner deploys a Docker container with bind mounts, the container's effective UID must match the runner user's UID — otherwise the next workflow's `actions/checkout@v4` cleanup step hits EACCES on bind-mounted files and the run cascades to total failure.**

Symptom — the failed run shows `actions/checkout@v4` failing with:

```
Deleting the contents of '/opt/actions-runner/_work/.../DeploymentGitActions'
Error: File was unable to be removed Error: EACCES: permission denied,
  unlink '/opt/actions-runner/_work/.../services/projects/.gitkeep'
```

…and every subsequent step fails because the workspace is empty (no `scripts/requirements.txt`, no `.git`, etc.).

Root cause — the IA Ignition image runs as `user: 0:0` (root) and the entrypoint reads `IGNITION_UID` / `IGNITION_GID` env vars to chown the data directories. Those data dirs include the **bind-mounted host paths** (`services/projects/`, `services/config/resources/`, etc., declared in docker-compose.yml under `volumes:`). After the container has run, those host directories are owned by `IGNITION_UID` on the host filesystem.

If `IGNITION_UID` (default: 1000) doesn't match the runner user's UID (github-runner is typically UID 999, a system user), the runner cannot unlink files in the chowned directories. The next workflow's checkout step starts by trying to clean the workspace and immediately fails on EACCES.

The deploy step only writes a few files into the bind mounts on each run, but `actions/checkout@v4`'s default cleanup tries to remove EVERYTHING in the workspace. So even files that were never in the bind mount fail to delete because the bind-mounted subdirs can't be entered.

Fix — match the container's `IGNITION_UID/GID` to the runner user's UID/GID at deploy time:

```yaml
- name: Write runtime .env
  run: |
    IGN_UID=$(id -u)   # the runner-user UID, since this step runs as github-runner
    IGN_GID=$(id -g)
    cat > .env <<EOF
    IGN_UID=${IGN_UID}
    IGN_GID=${IGN_GID}
    ...
```

Don't hard-code `IGN_UID=1000` — github-runner is created via `useradd --system` in `provision-runner.sh`, which assigns a UID under 1000. Different VMs may have different UIDs (depending on what other system users existed at install time), so derive at runtime.

Recovery on a host that's already in the broken state: stop the container by name (so the bind mount is released), then `sudo rm -rf` the runner's `_work` directory:

```bash
sudo docker stop <container-name>
sudo rm -rf /opt/actions-runner/_work/<repo>/<repo>
```

The next workflow recreates the workspace from scratch via `actions/checkout@v4`.

Don't `user: <runner-uid>:<runner-gid>` in the compose file — the IA entrypoint needs to start as root to do the chown, then drops privileges. Override `user:` and the chown step fails with permission errors. Stick with `user: 0:0` and control the destination UID via the env vars.

When this isn't the issue: if checkout works but a later step fails on bind-mount permissions, the runner UID may have CHANGED since the last deploy (rare — usually only happens after manual user-management or VM recreation). Same fix; same recovery path.

---

### Troubleshooting Rule: 2026-05-08 (seeded manually)

**Docker named volumes with bind options freeze the resolved absolute path at volume-creation time. Moving the compose project (e.g. relocating the runner from `/home/<user>/actions-runner` to `/opt/actions-runner`) breaks every subsequent `compose up` until you delete and recreate the volumes.**

Symptom — `compose up` fails with:

```
Error response from daemon: failed to populate volume:
  error while mounting volume '/var/lib/docker/volumes/<project>_<volume>/_data':
  failed to mount local volume:
  mount /home/<old-user>/actions-runner/_work/<repo>/<repo>/services/config/resources:
        /var/lib/docker/volumes/<project>_<volume>/_data,
  flags: 0x1000: no such file or directory
```

…even when the workspace is now at a completely different path. Compose also prints:

```
Volume "<project>_<volume>" exists but doesn't match configuration in compose file. Recreate (data will be lost)?
```

Root cause — when a named volume is declared with `driver_opts: type: none, device: <relative-path>, o: bind`, Docker resolves `<relative-path>` to an absolute path AT THE TIME OF FIRST `up` and stores that absolute path in the volume's metadata under `/var/lib/docker/volumes/<volume>/`. Subsequent `up` invocations look up the volume by NAME, see it already exists, and reuse the cached absolute path — they do NOT re-resolve the relative path against the current working directory.

This is fine in normal operation but bites hard whenever the compose project moves on the host filesystem. For self-hosted Actions runners the trigger is usually:

- Migrating from a manual `~/actions-runner/` install to a system-managed `/opt/actions-runner/`
- Renaming or recreating the runner work directory
- Switching the runner user (which changes the home dir)

Fix — delete the stale volumes so they get recreated with the current absolute path on the next `up`:

```bash
cd /<current-workspace>
sudo docker compose down -v   # tears down the project AND removes its volumes
sudo docker compose up -d     # recreates volumes with the current path
```

For volumes that bind to repo files (`services/config/resources/`, `services/projects/`), `down -v` is safe — the actual data lives in the bind-mount target (the repo files on disk), not the volume metadata. The volume is essentially a thin pointer; deleting it doesn't lose data.

For volumes that hold actual Docker state (e.g. `ignition-data` holding the gateway DB), `down -v` is destructive. If you need to preserve that one, target the bind-mount volumes specifically:

```bash
sudo docker volume rm <project>_<volume>   # only the affected ones
```

Identify which volumes have stale paths via:

```bash
sudo docker volume inspect <project>_<volume> | grep -i device
```

If `Device` shows a path that no longer exists on the host, the volume is stale.

Prevention at fleet scale — pin runners to a stable absolute path from day one (`/opt/actions-runner/`, never user homes), document that as part of the provisioning runbook, and don't hand-migrate. If a host's runner needs to relocate, the volumes for any compose project on that host must be torn down as part of the relocation.

When this isn't the issue: if `compose up` fails with a similar "no such file or directory" but the path in the error matches the CURRENT workspace, the issue is a missing source directory (e.g., `services/config/resources/` was deleted from the repo) — different problem, fix at the file level.

---

### Optimization Strategy: 2026-05-08 (seeded manually)

**For Dockerfiles that need to read optional files from the build context (modules, keystores, configs that may or may not be present), use `RUN --mount=type=bind,target=/...,readonly` instead of `COPY . /tmp/...` followed by cleanup. Avoids two real failure modes on Docker Desktop on Windows.**

Symptoms with the COPY-then-cleanup pattern:

1. **Build context bloat.** `COPY . /tmp/build-ctx/` ships the entire build context into a layer. If anything heavy lives in that directory — saved image tarballs, intermediate artifacts, large `.modl` collections — every build re-transfers and re-snapshots gigabytes. We saw `[internal] load build context ... transferring context: 2.14GB` from a `run-build-edge` invocation that left `edgeWithTransmission.tar` next to the Dockerfile.

2. **Cleanup fails with EACCES on Docker Desktop on Windows.** `rm -rf /tmp/build-ctx` errors out with "Permission denied" on the COPY'd files, even though `chown -R` ran successfully in the same RUN (which means we're root). The mechanism is unclear — likely an interaction between Windows file attributes, the WSL2 backend, and how BuildKit snapshots COPY layers on overlayfs — but the symptom is reliable: the build fails on cleanup, leaving the metro-keystore (private key) in the image at `/tmp/build-ctx/`.

The fix replaces both:

```dockerfile
# syntax=docker/dockerfile:1.6
ARG IGNITION_VERSION=8.3.6
FROM inductiveautomation/ignition:${IGNITION_VERSION}

RUN --mount=type=bind,target=/build-ctx,readonly \
    set -e; \
    if ls /build-ctx/*.modl >/dev/null 2>&1; then cp /build-ctx/*.modl ...; fi; \
    if [ -f /build-ctx/metro-keystore ]; then cp /build-ctx/metro-keystore ...; fi; \
    chown -R ignition:ignition ...
```

What changes:

- The build context is **mounted** read-only inside the RUN, not copied. No layer is written for the staged files. The mount disappears at the end of the RUN automatically — there's no `/tmp/build-ctx` left in the image at all.
- BuildKit handles the mount efficiently — only the files actually `cat`'d / `cp`'d from `/build-ctx` are pulled across.
- The `# syntax=docker/dockerfile:1.6` line at the top opts into BuildKit's mount syntax. Modern Docker Desktop has BuildKit on by default; the syntax directive makes the dependency explicit.

Belt-and-suspenders: **add a `.dockerignore`** in the build-context dir that excludes `*.tar`, `*.tar.gz`, `*.zip`, and other large outputs that shouldn't be inputs. Even with `--mount=type=bind`, BuildKit still reads the build context for the syntax pragma resolution and for any `COPY` instructions, so a fat context still costs IO. `.dockerignore` keeps the context small regardless.

When NOT to use this pattern:
- **Production multi-arch builds** that need cross-platform reproducibility through a fixed snapshot. The bind-mount happens at build-time on the build host's filesystem; there's no portable layer-cache for it. Usually fine for our use case (local + ubuntu-latest in CI), but multi-arch CI matrices may want explicit COPY layers for cache hits.
- **Older Docker** without BuildKit. Docker 19.03 needed `DOCKER_BUILDKIT=1`; older versions didn't support it at all. Modern Docker Desktop / Engine 23+ has BuildKit on by default. The syntax pragma also forces BuildKit, so an old client will fail loudly rather than silently produce a busted image.

---

### Troubleshooting Rule: 2026-05-08 (seeded manually)

**Git Bash on Windows mangles arguments that begin with `/` by treating them as POSIX paths and converting them to Windows paths (`C:/Program Files/Git/...`). Set `MSYS_NO_PATHCONV=1` and `MSYS2_ARG_CONV_EXCL='*'` at the top of any bash script that passes flag arguments like `-subj /CN=foo` to native Windows binaries.**

Symptom — running `bash scripts/generate-fleet-cert.sh` on Git Bash on Windows:

```
req: subject name is expected to be in the format /type0=value0/type1=value1/type2=...
This name is not in that format: 'C:/Program Files/Git/CN=edge-fleet'
```

The script passed `-subj /CN=edge-fleet` to openssl. Git Bash's MSYS layer saw `/CN=edge-fleet` start with a slash and "helpfully" rewrote it to `C:/Program Files/Git/CN=edge-fleet` (the path of the Git Bash install) before invoking the native Windows openssl. OpenSSL then rejected the malformed DN.

The fix is two env vars set at script entry:

```bash
export MSYS_NO_PATHCONV=1       # disables conversion (older MSYS)
export MSYS2_ARG_CONV_EXCL='*'  # disables conversion (newer MSYS2)
```

Both are harmless no-ops on Linux/macOS — they're just unset env vars there. On Git Bash and MSYS2 they instruct the runtime to leave path-looking arguments alone.

Affects any bash script that passes:
- `-subj /CN=...` to openssl
- `--subject /...` to other certificate / cryptography tools
- Anything where a `/`-prefixed arg is a flag value, not a path

Doesn't affect arguments that ARE paths (those should still be converted) — but for those, just use Windows-style paths or `cygpath` translations if needed.

For production scripting on Windows, prefer PowerShell — no MSYS layer, no path mangling. Keep bash versions for Linux runners (CI, IPCs) and the cross-platform-friendly subset of operations.

---
