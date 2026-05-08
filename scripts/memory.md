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

### Optimization Strategy: 2026-05-08 (seeded manually)

**For Edge fleets, override Ignition's per-gateway auto-generated metro keystore with a single shared fleet identity keystore. The Hub admin approves one cert; the entire fleet is trusted from then on.**

By default, every Edge generates a unique self-signed cert in its metro keystore on first boot. The Hub then quarantines each one as it dials in, and an admin must approve per IPC via the web UI. At one or two sites this is fine; at 50+ it's a per-site human bottleneck and basically forecloses on full automation.

The fleet-cert pattern collapses N approvals into 1:

1. **Generate one self-signed cert + private key once** (`scripts/generate-fleet-cert.{ps1,sh}`). Defaults: `CN=edge-fleet`, alias `edge-fleet`, password `changeit`, validity 1825 days, RSA 2048.
2. **Bake the PKCS12 into the image** at `/usr/local/bin/ignition/etc/fleet-keystore.p12`. Note the path is **outside** `/data/` — if you put it inside `/data/`, the named volume shadows it on first boot and Ignition can't find it.
3. **Tell Ignition to use it as the gateway's GAN identity** via four JVM system properties in `docker-compose.yml`:
   ```
   -Dgateway.metroKeystorePath=/usr/local/bin/ignition/etc/fleet-keystore.p12
   -Dgateway.metroKeystoreType=PKCS12
   -Dgateway.metroKeystoreAlias=${IGN_FLEET_KEYSTORE_ALIAS:-edge-fleet}
   -Dgateway.metroKeystorePassword=${IGN_FLEET_KEYSTORE_PASSWORD:-changeit}
   ```
   With these set, Ignition uses the supplied keystore as the gateway's GAN identity instead of auto-generating one. Without them (or with the file missing), Ignition silently falls back to its per-IPC auto-generated metro keystore — no error, just per-IPC certs again.
4. **Hub admin trusts `fleet-cert.crt` once.** Every Edge from then on shows up at the Hub identifying as the same TLS endpoint.

Distribution paths for the `.p12`:

- **Local build:** the keystore lives in `build/edgeGwBuild/fleet-keystore.p12` on the workstation. The Dockerfile picks it up via a conditional `RUN` (so its absence isn't an error). The image is private (GHCR), so the keystore travels inside it to IPCs.
- **CI build:** base64-encode the `.p12` and store as a `FLEET_KEYSTORE_BASE64` repo Secret. The Build Edge Image workflow decodes it into the build context before `docker build`. This keeps the private key out of the repo and out of operator-workstation drift.

Constraints / trade-offs:

- **The `.p12` contains the private key.** Anyone with image-pull access (or repo Secret access on the CI path) effectively has the fleet's TLS identity. Acceptable when the image registry is private and trusted; not acceptable in any model where a single-fleet-cert compromise can't be tolerated.
- **No zero-downtime cert rotation.** When the cert nears expiry, you regenerate, redistribute, and rolling-redeploy. For brief windows the Hub may see Edges from both old and new certs — keep both trusted at the Hub during cutover, or bring everything down for a short maintenance window.
- **Image-bake is necessary, not just config-bake.** The `.p12` must exist in the image (or somewhere readable by the JVM at boot). Mounting it at runtime is feasible but makes the deploy step responsible for distributing the private key, which is worse than having the registry distribute it via the image.

The conditional Dockerfile pattern (`RUN ... if [ -f /tmp/build-ctx/fleet-keystore.p12 ]; then cp ...; fi`) is what lets the same Dockerfile work in both modes: with the fleet keystore for production fleets, without it for dev / testing / single-IPC scenarios. Strict glob `COPY` would 1-or-fail at build time; the conditional path tolerates either input.

When NOT to use this: very small deployments (1-2 IPCs) where per-IPC manual approval is fine, or compliance regimes that mandate per-device unique TLS identity (some industrial security profiles do).

---
