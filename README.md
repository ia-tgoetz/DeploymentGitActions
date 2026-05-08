# Ignition 8.3 Edge — Automated Deployment

Automated deployment and configuration sync for Inductive Automation's Ignition 8.3 Edge on field Industrial PCs (IPCs), driven by GitHub Actions and a private GHCR-hosted Docker image with third-party modules baked in.

## How it works

1. **Image source:** a **derived Edge image** is built once from `build/edgeGwBuild/Dockerfile` (extends IA's base image and `COPY`s third-party `.modl` files into `user-lib/modules`). It's pushed to your private GHCR as `ghcr.io/<owner>/ignition-edge:<version>`. IPCs only ever pull from there — never from public registries, and never with a runtime `.modl` mount.
2. **Runner:** each IPC runs a self-hosted GitHub Actions runner registered against this repo (provisioned in one shot via `scripts/provision-runner.sh`).
3. **Trigger:** any push to `main` triggers `.github/workflows/deploy.yml`.
4. **Sync:** the runner pulls the derived image, writes a runtime `.env` from Secrets + the IPC hostname, then `docker compose down && up -d` with a health-check wait.
5. **Config-as-code:** Ignition projects and the file-based VCS config live in `services/projects/` and `services/config/resources/`, bind-mounted into the container.
6. **Gateway naming:** each IPC's Ignition gateway name automatically inherits the host's `hostname`, so the central GW's GAN view shows fleet members by IPC identity. Override with the `IGN_NAME` repo Secret if you need a custom name.
7. **Transmitter identity:** at deploy time, `scripts/configure-transmitter.sh` rewrites `edgeNodeId` in every Cirrus Link transmitter config under `services/config/resources/.../transmitter/<name>/config.json` to match the gateway name. Each IPC publishes to MQTT under its own edge-node ID without per-site config sprawl.
8. **Fleet identity (optional):** a single self-signed cert + PKCS12 keystore baked into the image gives every Edge in the fleet the same TLS identity to the Hub. The Hub admin approves one cert; the whole fleet is trusted. Without this, Ignition auto-generates a unique metro keystore per IPC and the Hub admin has to approve each one individually. See Phase 1.0.
9. **Fleet fan-out:** `config/fleet.txt` lists every IPC by hostname. The deploy workflow uses a matrix strategy that spawns one job per entry, each pinned to that IPC's runner via a hostname-specific label. A push to `main` deploys to **every** IPC in parallel; `fail-fast: false` keeps a bad IPC from cancelling the rest. Manual dispatch with an `ipc` input targets one IPC for canary deploys.

---

## Repository structure

```
.
├── .github/workflows/build-image.yml   # CI: builds & pushes the Edge image when build/edgeGwBuild/ changes
├── .github/workflows/deploy.yml        # CD: deploys to the IPC on every push to main
├── docker-compose.yml              # Production: Ignition Edge only
├── docker-compose.test.yml         # Adds a central GW container for local GAN testing
├── .env.example                    # Template — copy to .env per environment
├── build/
│   └── edgeGwBuild/
│       ├── Dockerfile              # Derived Edge image (base + .modl in user-lib/modules + optional metro-keystore in webserver/)
│       ├── modules.txt             # URLs of .modl files CI fetches before building
│       ├── fleet-cert.crt          # Public fleet identity cert — committed; Hub admin imports once to trust the whole fleet
│       └── .gitignore              # Excludes .modl binaries and metro-keystore (private key)
├── config/
│   ├── central-gateway.env         # GAN target details (per site, committed)
│   └── fleet.txt                   # IPC roster — one hostname per line; deploy workflow fans out to each
├── services/
│   ├── config/resources/           # Ignition VCS config (file-based gateway config)
│   ├── projects/                   # Ignition projects
│   └── pki/trusted/clients/        # Public certs to pre-trust — bind-mounted into Edge's GAN-client trust store
│       └── engine-demo.chariot.io.crt   # Hub's public GAN cert, pre-staged so first connect skips quarantine
├── run-build-edge.ps1              # Wrapper: fetch modules.txt, docker build, save to tar (Windows)
├── run-build-edge.sh               # Wrapper: fetch modules.txt, docker build, save to tar (Linux/macOS)
├── run-push-edge.ps1               # Wrapper: loads .env, pushes the prebuilt Edge tar to GHCR (Windows)
├── run-push-edge.sh                # Wrapper: loads .env, pushes the prebuilt Edge tar to GHCR (Linux/macOS)
└── scripts/
    ├── push-image-to-ghcr.ps1      # Push a derived image (tar or local) to GHCR (Windows)
    ├── push-image-to-ghcr.sh       # Push a derived image (tar or local) to GHCR (Linux/macOS)
    ├── provision-runner.sh         # One-shot: full IPC provisioning (Docker, UFW, runner)
    ├── load-image.sh               # IPC: ensure derived image is available (GHCR or tar)
    ├── health-check.sh             # IPC: poll /StatusPing until RUNNING
    ├── configure-gan.sh            # IPC: one-time GAN connection setup (legacy fallback)
    ├── configure-transmitter.sh    # Deploy-time: rewrites edgeNodeId in every Cirrus Link transmitter config to the IPC's hostname
    ├── generate-fleet-cert.ps1     # Generate the shared fleet identity cert + PKCS12 keystore (Windows)
    ├── generate-fleet-cert.sh      # Same, for Linux/macOS (uses openssl)
    ├── fetch-server-cert.ps1       # Fetch a remote server's public TLS cert and stage it under services/pki/trusted/clients/ (Windows)
    ├── fetch-server-cert.sh        # Same, for Linux/macOS (uses openssl)
    ├── deploy_agent.py             # Claude agent — runs on deploy failure, investigates, may record a lesson
    ├── memory.md                   # Persistent agent memory (auto-appended to)
    └── requirements.txt            # Python deps for deploy_agent.py
```

---

## Image variable convention

The compose file splits the image base from the tag:

```yaml
image: ${IGNITION_IMAGE:-ghcr.io/ia-tgoetz/ignition-edge}:${IGN_RELEASE:-8.3.6}
```

| Variable | What it holds | Example |
|---|---|---|
| `IGNITION_IMAGE` | Registry + repo path (no tag) | `ghcr.io/ia-tgoetz/ignition-edge` |
| `IGN_RELEASE` | Version tag only | `8.3.6` |

To bump versions you only change `IGN_RELEASE` (after rebuilding/repushing the derived image with the new base). To switch registries (e.g. fall back to Docker Hub for local dev) you only change `IGNITION_IMAGE`.

---

## Prerequisites

- A GitHub repo with **Branch protection on `main`** enabled (the runner has Docker access — protect what executes on it)
- GHCR enabled on your account/org
- One Linux IPC (Ubuntu Server 22.04 or 24.04 LTS recommended) with network access to `github.com` and `ghcr.io`
- A workstation with Docker (Windows / macOS / Linux) for the one-time image build

---

## Phase 1.0 — Fleet identity cert (one-time, optional but recommended at scale)

By default, every Edge gateway auto-generates its own unique TLS identity (the "metro keystore") on first boot. The Hub then quarantines each one and an admin has to click "approve" per IPC. At one or two sites this is fine; at 50+ it's a per-site bottleneck.

The fleet-cert pattern collapses that to a single approval. You generate one self-signed cert + private key, package it as a PKCS12 keystore (alias `metro-key`), and bake it into the image at the conventional path `/usr/local/bin/ignition/webserver/metro-keystore`. Ignition reads from that file by convention; the JVM property `-Dmetro.keystore.password=...` (set in `docker-compose.yml`) supplies the password. Every Edge then identifies as the same TLS endpoint to the Hub. The Hub admin approves the one cert once; the entire fleet is trusted.

This follows the workflow documented in *Setting Up Your Own Gateway Network Certificate* (Inductive Automation), with the CSR-to-CA step replaced by self-signing.

If you skip this phase, deployments still work — Ignition falls back to per-IPC auto-generated metro keystores and the Hub admin approves each.

### 1.0.1 Generate the fleet cert

From a workstation (does not need to be the IPC):

```powershell
.\scripts\generate-fleet-cert.ps1
```
```bash
bash scripts/generate-fleet-cert.sh
```

The cert's SAN list is built dynamically from `config/fleet.txt` — every hostname you've added becomes a `DNS:` SAN entry. To include IPs (only the `bash` script supports IP-typed SANs):

```bash
FLEET_IPS="192.168.1.10,192.168.1.20" bash scripts/generate-fleet-cert.sh
```

Outputs (in `build/edgeGwBuild/`):

| File | Purpose | Commit? |
|---|---|---|
| `fleet-cert.crt` | Public cert. Hand to whoever runs the Hub. | **Yes** — public certs are safe to commit and convenient to share |
| `metro-keystore` | PKCS12 keystore (cert + private key, alias `metro-key`). Baked into the image. | **No** — `.gitignore` excludes it. The private key gives anyone the fleet's TLS identity. |

Defaults: subject `CN=edge-fleet`, alias `metro-key` (fixed by Ignition convention), password `changeit`, validity 1825 days, RSA 4096. Override via flags / env vars (see the script header).

### 1.0.2 Distribute the keystore (pick one)

The keystore file must be present at `build/edgeGwBuild/metro-keystore` at image-build time so the Dockerfile can copy it into the image. Two paths:

- **Local-build path** — keep `metro-keystore` on the workstation that runs `run-build-edge.{ps1,sh}`. The Dockerfile picks it up automatically. The image is private (GHCR), so the keystore travels with it to the IPCs.
- **CI-build path** — base64-encode the file and store it as a GitHub Secret named `FLEET_KEYSTORE_BASE64`. The `Build Edge Image` workflow decodes it into the build context before `docker build`.

  ```powershell
  # Windows — copy to clipboard, then paste into the Secret value field
  [Convert]::ToBase64String([System.IO.File]::ReadAllBytes("build\edgeGwBuild\metro-keystore")) | Set-Clipboard
  ```
  ```bash
  # Linux/macOS
  base64 -w0 build/edgeGwBuild/metro-keystore | xclip -selection clipboard
  ```

  Add at `Settings → Secrets and variables → Actions → New repository secret`. If the password isn't the default `changeit`, also set `IGN_FLEET_KEYSTORE_PASSWORD`.

If the secret is unset (or the local file is missing), CI/local builds still succeed — the image just doesn't carry a fleet keystore and Edges fall back to per-IPC auto-generated ones.

### 1.0.3 Hand the public cert to the Hub admin

Email / Slack / commit `build/edgeGwBuild/fleet-cert.crt`. The Hub admin imports it once into the Hub's trusted certs (Config → Networking → Gateway Network → Certificates → trust the incoming cert). After that, every Edge that boots with the keystore connects without quarantine.

### 1.0.4 Rotation

The keystore has a fixed validity (5 years by default). When it nears expiry:

1. Regenerate with `generate-fleet-cert` (same alias / password to avoid coordinated config changes).
2. Re-upload the new base64 to the `FLEET_KEYSTORE_BASE64` Secret (or replace the local `.p12`).
3. Hand the new `fleet-cert.crt` to the Hub admin.
4. Trigger a rebuild + rolling redeploy. IPCs pulling the new image identify under the new cert.

There is no zero-downtime overlap with this pattern — for a brief window the Hub may see Edges from both old and new certs. If your fleet can't tolerate that, run two parallel keystores during cutover and keep both trusted at the Hub.

---

## Phase 1 — Build and publish the derived Edge image

This phase produces the image IPCs pull at deploy time: `ghcr.io/<owner>/ignition-edge:<version>` with all third-party `.modl` files baked into `user-lib/modules` and the fleet keystore (if present) at `etc/fleet-keystore.p12`. Done once per module- or keystore-change, not per deploy.

There are two paths. **CI is the recommended one** — zero hands-on work after a config change. The local-build path is for first-time setup, air-gapped scenarios, or when you can't push to GHCR from CI for some reason.

### 1A — CI path (recommended)

`.github/workflows/build-image.yml` builds and pushes the image whenever anything under `build/edgeGwBuild/` changes on `main`. To trigger it, just edit the relevant file and push:

| Change | What to edit | Result |
|---|---|---|
| Add a new module | Append a URL line to `build/edgeGwBuild/modules.txt` | CI rebuilds, downloads the new module, pushes a new image |
| Upgrade an existing module's version | Change the URL in `modules.txt` to the new version | CI rebuilds with the new `.modl` |
| Update the Dockerfile (e.g. new base version) | `build/edgeGwBuild/Dockerfile` | CI rebuilds with the new base |
| Force a rebuild without changing anything | **Actions → Build Edge Image → Run workflow** | Manual trigger, optional `ignition_version` input |

The workflow runs on a GitHub-hosted runner (`ubuntu-latest`) — your IPC's runner is not used for builds, only deploys. Each successful build pushes two tags, both mutable:

- `ghcr.io/<owner>/ignition-edge:<IGN_RELEASE>` — version-pinned (e.g. `8.3.6`); what `deploy.yml` pulls
- `ghcr.io/<owner>/ignition-edge:latest` — always the most recent build, regardless of version

The Build Edge Image workflow run page also prints a verification step showing what `.modl` files made it into the published image.

### 1B — Local-build path (alternative)

Use this when you can't run CI (air-gapped tooling, debugging the build itself, etc.). Two wrappers handle the full flow from the repo root:

1. **Get a GHCR PAT** with `write:packages` + `read:packages` scopes from <https://github.com/settings/tokens/new>.
2. **Clone the repo** and copy `.env.example` to `.env`. Set `GHCR_OWNER`, `GHCR_PAT`, and `IGN_RELEASE`.
3. **Build the image** — fetches anything missing per `modules.txt`, runs `docker build`, saves the result to `build/edgeGwBuild/edgeWithTransmission.tar`:
   ```powershell
   .\run-build-edge.ps1
   ```
   ```bash
   bash run-build-edge.sh
   ```
4. **Push to GHCR** — loads the tar, tags it as `ignition-edge:${IGN_RELEASE}`, pushes:
   ```powershell
   .\run-push-edge.ps1
   ```
   ```bash
   bash run-push-edge.sh
   ```

The build wrapper skips re-downloading any `.modl` already present in `build/edgeGwBuild/`. To force a refresh, delete the local file and re-run.

If you prefer to drive `docker build` and `docker push` directly without the wrappers, the equivalent is:

```bash
docker build \
  -t edge-with-transmission:8.3.6 \
  --build-arg IGNITION_VERSION=8.3.6 \
  ./build/edgeGwBuild

GHCR_OWNER=ia-tgoetz GHCR_PAT=<token> \
  bash scripts/push-image-to-ghcr.sh edge-with-transmission:8.3.6 ignition-edge:8.3.6
```

### 1C — First-time GHCR package setup

Whether you used CI or local build, the **first** time a new package name appears in your GHCR account, configure access **once**:

1. Visit <https://github.com/users/ia-tgoetz/packages/container/ignition-edge/settings>
2. **Change visibility → Private**
3. **Manage Actions access → Add Repository → DeploymentGitActions → Read**

Without step 3, the deploy workflow's auto-injected `GITHUB_TOKEN` will 403 when trying to pull.

---

## Phase 2 — Configure the GitHub repository

### 2.1 Add Secrets

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Value |
|---|---|
| `GATEWAY_ADMIN_USERNAME` | Initial admin username for the gateway |
| `GATEWAY_ADMIN_PASSWORD` | Initial admin password (use a strong one) |
| `FLEET_KEYSTORE_BASE64` *(optional)* | Base64-encoded `fleet-keystore.p12` from Phase 1.0. Only needed for the CI-build path. If unset, CI builds without a fleet keystore and Edges fall back to per-IPC auto-generated metro keystores. |
| `IGN_FLEET_KEYSTORE_PASSWORD` *(optional)* | Override the fleet keystore password if you generated the `.p12` with something other than the default `changeit`. |
| `ANTHROPIC_API_KEY` *(optional)* | Powers the auto-troubleshooting agent (`scripts/deploy_agent.py`). Without it, deploy failures are surfaced as workflow errors only — no auto-investigation. Get from <https://console.anthropic.com/settings/keys>. |

`GITHUB_TOKEN` is auto-provided by GitHub Actions and is what the workflow uses to authenticate to GHCR — no extra secret needed.

### 2.2 (Recommended) Enable branch protection on `main`

`Settings → Branches → Add rule` for `main`:
- Require pull request before merging
- Restrict who can push

The self-hosted runner executes whatever's in `main` with Docker root on the IPC. Treat `main` like production.

### 2.3 Per-site config

Edit `config/central-gateway.env` and fill in the central gateway details for the site this IPC will join, then commit. (If sites differ, use a branch per site or environment-specific config files.)

---

## Phase 3 — Provision the IPC

A single script handles everything: Docker install, firewall ports, dedicated service user, runner registration, and systemd service. Idempotent — safe to re-run.

### 3.1 Get a one-time runner token

`Settings → Actions → Runners → New self-hosted runner` → copy the token (expires in ~1 hour).

### 3.2 Run the provisioning script

Clone the repo on the IPC, then:

```bash
git clone https://github.com/ia-tgoetz/DeploymentGitActions.git
cd DeploymentGitActions
sudo bash scripts/provision-runner.sh <one-time-token>
```

That's it. The script:

| Step | What it does |
|---|---|
| 1 | **Grows the root LV to use the full disk** — Ubuntu Server's installer leaves ~50% of the disk unallocated by default; this detects `VFree > 100 MB` in the VG and runs `lvextend + resize2fs` (or `xfs_growfs`/`btrfs filesystem resize` based on the FS type). No-op on a correctly-sized host. |
| 2 | Installs `curl`, `git`, `jq`, `ufw`, `ca-certificates`, `python3` + `python3-venv` |
| 3 | Installs Docker via `get.docker.com` (skips if already present) |
| 4 | Creates the `github-runner` system user (no login shell, in `docker` group) |
| 5 | Configures UFW: allows `OpenSSH`, then opens Ignition ports `8088`, `8043`, `8060` |
| 6 | Downloads the latest GitHub Actions runner into `/opt/actions-runner` |
| 7 | Registers it with GitHub using your token, name = hostname, labels = `self-hosted,Linux,X64,ipc,<hostname>` (the hostname label is what deploy.yml's matrix targets) |
| 8 | Installs and starts the systemd service running as `github-runner` |
| 9 | Pre-creates `/opt/ignition-images/` for the optional tar fallback |

After it completes, verify in GitHub: `Settings → Actions → Runners` — the runner should appear as **Idle** with the IPC's existing hostname, and its label list should include that hostname.

> **The script does not change the IPC's hostname.** It reads `$(hostname)` and reuses it as the runner name, the runner's targeting label, and (at deploy time) the Ignition gateway name. Set the hostname through your normal IPC provisioning before running this script (Proxmox template, cloud-init, `hostnamectl`, whatever you prefer).
>
> To override the runner name without changing the host's hostname:
> ```bash
> sudo bash scripts/provision-runner.sh <token> custom-runner-name
> ```
> If you do this, also use `custom-runner-name` (not the host's actual hostname) when you add the IPC to `config/fleet.txt`.

### 3.3 Add the IPC to the fleet roster

The provisioning script registers the runner with GitHub but does **not** automatically add the IPC to `config/fleet.txt`. That's a deliberate two-step gate so a half-provisioned IPC isn't accidentally pulled into deploys.

Edit `config/fleet.txt` and append the new hostname:

```
edge-east
edge-site-dallas
edge-site-houston   # <-- new IPC added here
```

Commit and push. The next deploy fans out to it.

### 3.4 (Optional) Pre-stage the image tar for air-gapped fallback

If the IPC may temporarily lose internet, pre-stage a tar so the deploy still works:

```bash
sudo mkdir -p /opt/ignition-images

# From a workstation with internet:
docker pull ghcr.io/ia-tgoetz/ignition-edge:8.3.6
docker save ghcr.io/ia-tgoetz/ignition-edge:8.3.6 -o ignition-edge-8.3.6.tar
# scp ignition-edge-8.3.6.tar to the IPC, then:
sudo mv ignition-edge-8.3.6.tar /opt/ignition-images/
```

`scripts/load-image.sh` tries GHCR first and falls back to this tar automatically.

---

## Phase 4 — First deployment

Push any change to `main` (or use **Actions → Deploy Ignition Edge → Run workflow**). The workflow has two jobs:

| Job | Where | What |
|---|---|---|
| `discover` | `ubuntu-latest` (GitHub-hosted) | Reads `config/fleet.txt` (or the `ipc` workflow input) and emits a JSON array of target hostnames. |
| `deploy` | `[self-hosted, <hostname>]` (matrix, one job per IPC) | Runs the actual deployment. With `fail-fast: false` so one bad IPC doesn't cancel the others. |

Each matrix `deploy` job runs on its target IPC's runner and:

1. Verifies Docker access
2. Logs in to GHCR using the workflow's `GITHUB_TOKEN`
3. Pulls `ghcr.io/<owner>/ignition-edge:<version>` (or loads from tar fallback)
4. Writes a runtime `.env` (`IGN_NAME = matrix.ipc`)
5. Rewrites the transmitter `edgeNodeId` to the IPC's hostname
6. `docker compose down --timeout 60 && up -d`
7. Polls `http://localhost:8088/StatusPing` until it returns `RUNNING`
8. Cleans up the runtime `.env`

**Targeting a single IPC** (canary deploys, debugging): use `Run workflow → ipc = <hostname>`. The `discover` job sees the input and emits a one-element matrix; only that runner picks up the job.

Open `http://<ipc-ip>:8088` in a browser to verify. Log in with the admin credentials from the Secrets. Quick post-deploy checklist:

| Where | What to see | If wrong |
|---|---|---|
| **Config → Modules** | Cirrus Link MQTT Transmission as `Trial / ACTIVE` | See "Module shows up under Config → Modules but state is `default`" in Troubleshooting |
| **Config → Networking → Gateway Network** | Outgoing connection to the Hub, state `Connected` (not `Quarantined`, not `Disabled`) | Check `services/pki/trusted/clients/` has the Hub's cert; check `config/central-gateway.env` values |
| **Config → Networking → Gateway Network → Identity** *(if using Option B)* | Cert subject = `CN=edge-fleet` (or whatever you set in `generate-fleet-cert`), not the auto-generated `ip-x.x.x.x:8060` | Data volume holds the old auto-generated cert; SSH to the IPC, `docker compose down -v`, redeploy |

> **First-boot gotcha:** the workflow's restart step runs `docker compose down` (no `-v`), so the named volume `*_ignition-data` persists between deploys. If a previous deploy left the volume in a half-initialized state (failed init loop, partial module install, etc.), boot symptoms include a phantom module entry under Config → Modules with state `default` and a `W [g.ModuleManager]: The file for module ... is missing` log line. Fix: SSH to the IPC and wipe the volume **once** before triggering a fresh deploy:
>
> ```bash
> cd /home/tomg55/actions-runner/_work/DeploymentGitActions/DeploymentGitActions
> docker compose down -v
> docker volume ls | grep deploymentgitactions   # should be empty
> ```
>
> Then push a commit to trigger a clean redeploy. This is **only needed if a previous deploy failed**; healthy steady-state deploys reuse the volume so the gateway DB persists across releases.

---

## Phase 5 — Gateway Network outgoing connection

The Edge gateway opens an outgoing GAN connection to the Hub on first boot. Two pieces:

### 5.1 Connection parameters

`config/central-gateway.env` defines the connection (host, port, SSL, ping rate). The deploy workflow reads it and exports `GATEWAY_NETWORK_0_*` env vars on the container; Ignition picks them up at first DB-init and creates the connection. Edit per site and commit:

```bash
# config/central-gateway.env
GAN_HOST=engine-demo.chariot.io
GAN_PORT=8060
GAN_PINGRATE=1000
GAN_ENABLESSL=true
GAN_ENABLED=true
```

These env vars are honored only on the first boot of a fresh gateway DB (same constraint as `GATEWAY_ADMIN_PASSWORD`). Once the connection exists in the DB, manage further changes via the gateway web UI or wipe the volume to re-seed.

### 5.2 Pre-trusting the Hub's certificate

By default Ignition quarantines the Hub's TLS cert on first connect, requiring an admin to manually approve it via the web UI. To bypass that, drop the Hub's public `.crt` into `services/pki/trusted/clients/`. The `engine-demo.chariot.io.crt` is **already committed**, so for that Hub the trust is in place out of the box.

For a different Hub, fetch its public cert via the helper script (no `openssl` needed on Windows):

```powershell
.\scripts\fetch-server-cert.ps1 my-hub.example.com 8060
```
```bash
bash scripts/fetch-server-cert.sh my-hub.example.com 8060
```

Output lands at `services/pki/trusted/clients/<hostname>.crt`. Commit it (public certs are not sensitive).

If you'd rather extract by hand:

```bash
echo | openssl s_client -connect engine-demo.chariot.io:8060 \
  -servername engine-demo.chariot.io 2>/dev/null \
  | openssl x509 -outform PEM > services/pki/trusted/clients/engine-demo.chariot.io.crt
```

The directory is bind-mounted at `/usr/local/bin/ignition/data/config/local/ignition/gateway-network/client/security/pki/trusted/certs/` inside the container — Ignition's GAN-client trust store — so any cert present at first boot is trusted before the GAN connection attempts its initial handshake.

### 5.3 Verify

After the deploy completes, the connection should appear at:

`http://<ipc-ip>:8088/web/config/networking.ganconfig`

…with state `Connected` (not `Quarantined` and not `Disabled`). If you see `Quarantined` despite the cert being staged, the cert filename or PEM encoding may be off — check `docker logs <container> | grep -i 'pki\|cert\|quarantine'` for the specific complaint.

### 5.4 Edge GAN security posture (outbound-only)

`services/config/resources/core/ignition/gateway-network-settings/config.json` locks the Edge's GAN to outbound-only with strict authentication:

| Setting | Value | Why |
|---|---|---|
| `allowIncoming` | `false` | Edges don't accept dial-ins. Only the Hub initiates outbound; nothing on the Edge listens for incoming GAN. Closes that surface entirely. |
| `requireSSL` | `true` | All GAN traffic uses TLS — no plaintext fallback even on internal networks. |
| `requireTwoWayAuth` | `true` | Both sides present and validate certs. The Hub trusts the fleet cert (Phase 1.0); the Edge trusts the Hub via Phase 5.2. |
| `securityPolicy` | `ApprovedOnly` | Even if `allowIncoming` were ever flipped to `true`, only certs that were explicitly approved would be honored. Defense-in-depth. |

Combined effect: an Edge can only originate a TLS-mutual-auth connection to a Hub it already trusts; nothing else can reach in. If a site requires the Edge to also accept incoming GAN (e.g. for centralized push delivery), flip `allowIncoming` to `true` and add the originator's cert to `services/pki/trusted/clients/`. Otherwise leave it as committed.

### 5.5 Manual fallback (legacy)

If you ever need to add or modify a GAN connection on an already-running gateway without wiping the volume, `scripts/configure-gan.sh` calls Ignition's REST API to do it imperatively. It's no longer the primary path (the env-var seeding handles fresh deploys cleanly) but remains in the repo for ad-hoc per-site adjustments.

---

## Local test environment

For exercising GAN end-to-end locally, `docker-compose.test.yml` adds a second Ignition container that acts as the central gateway:

```bash
cp .env.example .env
# Fill in GATEWAY_ADMIN_USERNAME / PASSWORD at minimum

docker compose -f docker-compose.yml -f docker-compose.test.yml up -d
```

| Service | URL |
|---|---|
| Ignition Edge | <http://localhost:8088> |
| Central Ignition GW | <http://localhost:9088> |

Tear down:

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml down -v
```

---

## Operations

### Adding or upgrading a third-party module

1. Append (or modify) the URL in `build/edgeGwBuild/modules.txt`
2. Append the module ID to `ACCEPT_MODULE_LICENSES` and `ACCEPT_MODULE_CERTS` in `.env.example` and `.github/workflows/deploy.yml`'s `.env` write step

   > Get the canonical module ID from the `.modl` itself:
   > ```bash
   > python3 -c "import zipfile; print(zipfile.ZipFile('<file>.modl').read('module.xml').decode())"
   > ```
   > The `<id>` element is what `ACCEPT_MODULE_*` matches against — not the display name, not the resource-folder path.

3. Push to `main`. The **Build Edge Image** workflow rebuilds and re-publishes; the **Deploy Ignition Edge** workflow then pulls the new image on its next run.

> ⚠️ **Module-version upgrades require a data-volume wipe on each IPC** to actually take effect. Ignition extracts modules from `user-lib/modules/` into `/data/modules/` (the named volume) on first install, then loads from the volume copy on subsequent boots. A new image with a newer module version doesn't override the cached extraction.
>
> For the new version to land:
> ```bash
> docker compose down -v   # wipes the data volume — DB and module cache reset
> ```
> Then trigger a deploy. Skip this and the IPC keeps running the old version even though it pulled the new image.
>
> `down -v` is destructive (gateway DB resets); fine for Edge IPCs whose DB content is reproducible from `services/` bind mounts and pre-staged config, but never run it on a gateway whose DB holds state you can't recreate. At fleet scale this becomes a sequenced rolling upgrade rather than a fire-and-forget `git push`.

### Bumping the Ignition base version

1. Update the `FROM inductiveautomation/ignition:<version>` line in `build/edgeGwBuild/Dockerfile`
2. Update `IGN_RELEASE` in `.env.example` and `.github/workflows/deploy.yml` (the `IGN_RELEASE=...` line in the `.env` write step)
3. Push to `main` — Build Edge Image rebuilds against the new base, Deploy Ignition Edge picks it up on the next run.

### Rolling back

Tags are mutable, so rollback works by re-publishing the previous content. Two ways:

- **Revert + rebuild:** revert the commit that triggered the bad build (or re-push the previous `Dockerfile`/`modules.txt` state). Build Edge Image republishes the previous content under `:<IGN_RELEASE>` and `:latest`.
- **Pin to an earlier digest:** if you've recorded the immutable digest (`sha256:...`) of a previous good build, you can pin `IGN_RELEASE` directly at that digest. The build workflow doesn't push per-commit tags, so this only works if you saved the digest yourself before the bad build.

For quick fleet recovery the revert-and-rebuild path is the right one. If you need true immutable rollback in the future, add `:<IGN_RELEASE>-<short-sha>` back to the workflow's `tags:` list.

### Changing the central gateway address

1. Edit `config/central-gateway.env`, commit, push.
2. SSH to each affected IPC and re-run `bash scripts/configure-gan.sh`.

### Tuning resource limits

The container has a memory and CPU cap to keep a runaway gateway from starving the IPC. Defaults:

| Variable | Default | What it does |
|---|---|---|
| `IGN_MAX_HEAP` | `2048` | JVM `-Xmx` in MB (max Java heap inside the container) |
| `IGN_MEM_LIMIT` | `4g` | Docker container memory cap (must exceed `IGN_MAX_HEAP` to leave room for off-heap, DB cache, OS overhead) |
| `IGN_CPUS` | `2.0` | CPU quota (decimal; can be fractional like `1.5`) |

Override per-IPC by setting any of these in the IPC's runtime `.env` (which `deploy.yml` writes per-deploy) — to make site-specific overrides stick across deploys, modify the `.env` write step in the workflow or set them as repo Secrets and reference them there.

A site running multiple containers, low-spec hardware, or a high-volume Edge with many tags should size up. A small dev IPC can size down to `IGN_MAX_HEAP=1024 IGN_MEM_LIMIT=2g IGN_CPUS=1.0`.

---

## Auto-troubleshooting agent

When a deploy step fails on the runner, `deploy.yml` invokes `scripts/deploy_agent.py` — a Claude (`claude-sonnet-4-6`) tool-use agent that investigates the IPC and may append a lesson to `scripts/memory.md`. The agent has four tools:

| Tool | Purpose |
|---|---|
| `get_docker_logs` | Tail logs from a named container |
| `check_disk_space` | `df -h` on the host |
| `read_local_file` | Read a file — **restricted** to paths under the repo or `/var/log/`; blocks anything matching credential / secret / SSH-key patterns |
| `record_lesson` | Append a Markdown entry to `scripts/memory.md` (committed and pushed by the workflow) |

Safety:

- Hard cap of 15 tool-use iterations per invocation
- System prompt explicitly forbids reading or writing credentials/PII; the file-read tool enforces a path allowlist + denylist independently
- Memory file commits use `[skip ci]` and the workflow trigger has `paths-ignore: scripts/memory.md`, so an agent-authored lesson cannot trigger another deploy
- Prompt caching is enabled on the system prompt so iteration cost is mostly cache reads after the first call

Set `ANTHROPIC_API_KEY` in repo Secrets to enable; the agent silently no-ops if the key is missing. Memory entries are public — do not edit them by hand to add anything sensitive.

### Adding lessons manually

If the agent isn't running (no API key) but you want to capture a lesson, append it to `scripts/memory.md` directly. Use the same format the agent uses, so when the agent does come online its `<memory>` context stays consistent:

```markdown
### Troubleshooting Rule: YYYY-MM-DD

**Short title summarizing the rule.**

Body explaining the symptom, root cause, and fix. Include enough detail
that a future agent (or human) can recognize the same failure pattern in
new logs.

---
```

Use `Troubleshooting Rule:` for bug fixes / failure-recovery patterns, or `Optimization Strategy:` for pipeline / cost / latency improvements. End every entry with `---` on its own line.

Commit with `[skip ci]` in the message so the auto-commit doesn't trigger a deploy:

```bash
git add scripts/memory.md
git commit -m "memory: <short description> [skip ci]"
git push
```

The workflow's `paths-ignore: scripts/memory.md` already prevents memory-only pushes from triggering a deploy, but the `[skip ci]` is good etiquette for clarity.

---

## Troubleshooting

**Module shows up under Config → Modules but state is `default` (not `Trial`/`ACTIVE`); log warns "The file for module ... is missing"**
The named volume `*_ignition-data` has stale catalog state from a prior failed boot. Wipe it:
```bash
docker compose down -v
docker volume ls | grep deploymentgitactions   # confirm it's gone
```
Then redeploy. See the "First-boot gotcha" callout in Phase 4.

**Module shows the wrong version (e.g. image has 5.0.3 but gateway shows 5.0.0)**
Ignition extracts modules into `/data/modules/` on first install, then loads from there. New image versions are shadowed by the cached extraction. Same fix as above: `docker compose down -v` then redeploy. See the warning under "Adding or upgrading a third-party module" in Operations.

**Runner shows offline in GitHub UI**
```bash
sudo ~/actions-runner/svc.sh status
sudo journalctl -u actions.runner.* -f
```
Or, if the runner was provisioned via `provision-runner.sh`:
```bash
sudo systemctl status 'actions.runner.*'
```

**Container won't pull from GHCR (403 Forbidden)**
- Verify the package is shared with the repo: GHCR package settings → **Manage Actions access** → add `DeploymentGitActions`.
- Verify `GITHUB_TOKEN` has `packages:read` (granted via `permissions:` block in the workflow).

**Container starts but health check fails for >5 minutes**
First-boot init takes 3–5 minutes (chown 1600+ files, JVM start, fresh DB init, module load). Health-check timeout is 10 minutes by default. If it still fails:
```bash
docker logs <container-name> --tail 200
docker exec -it <container-name> curl -sf http://localhost:8088/StatusPing
```
Look for init-loop signatures (e.g. repeating `Creating init.properties`) — usually a CLI flag mismatch like `-h`/`-s` without `-a`.

**File ownership issues on bind mounts**
Set `IGN_UID` / `IGN_GID` in `.env` to match the host user that owns `services/`. The compose runs as `user: 0:0` inside the container, so this is rarely an issue in practice.

**PowerShell complains about `VAR=value` syntax**
That's bash syntax. On Windows use `$env:VAR = "value"` on its own line, then run the script. See Phase 1.2.

**`./svc.sh: command not found`**
You ran `svc.sh install` before `config.sh` registered the runner. `svc.sh` is generated by `config.sh`, not extracted from the runner tarball. Run `config.sh` first; see `provision-runner.sh` for the correct sequence.

**Need to wipe state and start fresh**
```bash
docker compose down -v   # -v removes the named volumes (DB, modules, logs)
```
Bind-mounted directories (`services/projects/`, `services/config/resources/`) are unaffected — they're files in the repo, not in volumes.

---

## Future automation & optimization

Things worth doing once the fleet starts to scale beyond a handful of IPCs:

### Deploy pipeline

- **Smoke test before publish.** Have Build Edge Image bring up `docker-compose.test.yml` against the freshly-built image, poll `/StatusPing`, and verify the third-party module shows as `Running` via the gateway REST API. Failed smoke = no publish.
- **Sign published images.** Add cosign / sigstore signing to Build Edge Image; deploy.yml verifies the signature before `docker compose up`. Hardens the supply chain against a compromised PAT or registry.

### Edge runtime

- **Health-check uses StatusPing JSON parsing.** Current `health-check.sh` greps for the literal string `RUNNING`; if IA changes the response shape it breaks silently. Parse with `jq` and assert on `.state == "RUNNING"`.
- **GAN auto-configuration.** `scripts/configure-gan.sh` is currently a manual SSH step. Wire it into `deploy.yml` to run if `config/central-gateway.env` has `CENTRAL_GW_HOST` set (skip otherwise). Idempotent: only adds the connection if it doesn't already exist.

### Per-site config at scale

- **Branch-per-site or external config service.** `config/central-gateway.env` works for one or two sites; at 150+ it becomes a merge-conflict farm. Options: branch-per-site (each IPC's runner pulls its own branch), or fetch site-specific config from an external service (Vault, Consul, S3) at deploy time.
- **Hostname-derived tag/label injection.** The IPC hostname already drives the gateway name; could also drive site/region labels in Ignition, GAN connection naming, and tag prefixes — fewer per-site overrides needed.

### Observability

- **Centralized log aggregation.** Pipe `docker logs` from every IPC to a central Loki / Splunk / CloudWatch endpoint. Structured per-IPC logs make 150-site debugging tractable.
- **Fleet-wide health dashboard.** Grafana board reading `/StatusPing` and module-state from each IPC. Useful for catching the "gateway boots but a module silently failed" pattern that bit us during initial setup.
- **Deploy-result webhook.** The workflow already has `if: failure()` for the agent; also send a webhook to Slack/Teams on deploy success/failure for faster human awareness at scale.

### Security & operations

- **Branch protection enforced on `main` for everyone.** Currently configured but admins (you) can bypass. At fleet scale, enforce strictly — every change goes through PR review since the runner executes whatever lands.
- **Rotate the initial gateway admin password.** `GATEWAY_ADMIN_PASSWORD` only applies on first-DB-init. Document a runbook for password rotation via the gateway REST API once a fleet is live (no `down -v` allowed at that point — would wipe production data).
- **Backup automation.** Schedule periodic `gwbk` exports from each gateway to a central object store. The current setup has no disaster-recovery story for an IPC that loses its disk.
- **Fast-rolling tag deployments.** Add a `deploy.yml` input that lets you target a subset of runners by label (e.g. canary 5% of IPCs first). Currently every runner that picks up the workflow runs it.

### Repo hygiene

- **Decide what to do with `services-example/` and `Example Files/`.** They're reference material that informed the current design but aren't used at deploy time. Either move under `docs/reference/` and add a header noting their status, or remove and rely on git history for retrieval.
- **CI validation of compose / Dockerfile.** Add a workflow that runs `docker compose config` and `hadolint build/edgeGwBuild/Dockerfile` on every PR. Catches typos before they hit a runner.
