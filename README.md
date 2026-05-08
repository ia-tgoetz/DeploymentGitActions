# Ignition 8.3 Edge — Automated Deployment

Automated deployment and configuration sync for Inductive Automation's Ignition 8.3 Edge on field Industrial PCs (IPCs), driven by GitHub Actions and a private GHCR-hosted Docker image.

## How it works

1. **Image source:** the Ignition image is mirrored from Docker Hub into your private GitHub Container Registry once. IPCs only ever pull from `ghcr.io/<owner>/ignition:<version>`, never from public registries.
2. **Runner:** each IPC runs a self-hosted GitHub Actions runner registered against this repo (provisioned in one shot via `scripts/provision-runner.sh`).
3. **Trigger:** any push to `main` triggers `.github/workflows/deploy.yml`.
4. **Sync:** the runner pulls the latest repo, writes a runtime `.env` from Secrets + the IPC hostname, then `docker compose down && up -d` with a health-check wait.
5. **Config-as-code:** Ignition projects and the file-based VCS config live in `services/projects/` and `services/config/resources/`, bind-mounted into the container.
6. **Gateway naming:** each IPC's Ignition gateway name automatically inherits the host's `hostname`, so the central GW's GAN view shows fleet members by IPC identity. Override with the `IGN_NAME` repo Secret if you need a custom name.

---

## Repository structure

```
.
├── .github/workflows/deploy.yml    # CI/CD workflow — runs on every push to main
├── Dockerfile                      # Derived image: base GHCR + services/modules/*.modl
├── docker-compose.yml              # Production: Ignition Edge only (build + run)
├── docker-compose.test.yml         # Adds a central GW container for local GAN testing
├── .env.example                    # Template — copy to .env per environment
├── config/
│   └── central-gateway.env         # GAN target details (per site, committed)
├── services/
│   ├── config/resources/           # Ignition VCS config (file-based gateway config)
│   ├── projects/                   # Ignition projects
│   └── modules/                    # Third-party .modl files (gitignored, fetched per IPC)
├── run-mirror.ps1                  # Wrapper: loads .env then runs mirror (Windows)
├── run-mirror.sh                   # Wrapper: loads .env then runs mirror (Linux/macOS)
└── scripts/
    ├── mirror-to-ghcr.ps1          # One-time: mirror image into GHCR (Windows)
    ├── mirror-to-ghcr.sh           # One-time: mirror image into GHCR (Linux/macOS)
    ├── fetch-modules.ps1           # One-time: download .modl files (Windows)
    ├── fetch-modules.sh            # One-time: download .modl files (Linux/macOS)
    ├── provision-runner.sh         # One-shot: full IPC provisioning (Docker, UFW, runner)
    ├── load-image.sh               # IPC: ensure image is available (GHCR or tar)
    ├── health-check.sh             # IPC: poll /StatusPing until RUNNING
    ├── configure-gan.sh            # IPC: one-time GAN connection setup
    ├── deploy_agent.py             # Claude agent — runs on deploy failure, investigates, may record a lesson
    ├── memory.md                   # Persistent agent memory (auto-appended to)
    └── requirements.txt            # Python deps for deploy_agent.py
```

---

## Image variable convention

The compose file splits the image base from the tag:

```yaml
image: ${IGNITION_IMAGE:-ghcr.io/ia-tgoetz/ignition}:${IGN_RELEASE:-8.3.6}
```

| Variable | What it holds | Example |
|---|---|---|
| `IGNITION_IMAGE` | Registry + repo path (no tag) | `ghcr.io/ia-tgoetz/ignition` |
| `IGN_RELEASE` | Version tag only | `8.3.6` |

To bump versions you only change `IGN_RELEASE`. To switch registries (e.g. fall back to Docker Hub for local dev) you only change `IGNITION_IMAGE`.

---

## Prerequisites

- A GitHub repo with **Branch protection on `main`** enabled (the runner has Docker access — protect what executes on it)
- GHCR enabled on your account/org
- One Linux IPC (Ubuntu Server 22.04 or 24.04 LTS recommended) with network access to `github.com` and `ghcr.io`

---

## Phase 1 — One-time setup on a workstation

This phase mirrors IA's official image into your GHCR. Done once per Ignition version bump.

### 1.1 Create a GitHub Personal Access Token

Go to <https://github.com/settings/tokens/new> and create a classic token with these scopes:
- `write:packages`
- `read:packages`
- `repo` (auto-selected)

Save the token somewhere safe. **Never paste it into chat, commits, or shared docs.**

### 1.2 Clone the repo and configure

```powershell
git clone https://github.com/ia-tgoetz/DeploymentGitActions.git
cd DeploymentGitActions
copy .env.example .env
```

Open `.env` and fill in at minimum:
```
GHCR_OWNER=ia-tgoetz
GHCR_PAT=<your-new-token>
```

`.env` is gitignored, so the PAT stays local.

### 1.3 Run the mirror

The wrapper scripts at the repo root read `.env`, export each variable, and call the platform-appropriate mirror script.

#### Windows (PowerShell)

```powershell
.\run-mirror.ps1
```

#### Linux / macOS / WSL / Git Bash

```bash
bash run-mirror.sh
```

If you'd rather not store the PAT in `.env`, you can set the three variables inline and call the mirror script directly:

```powershell
# PowerShell
$env:GHCR_OWNER  = "ia-tgoetz"
$env:IGN_RELEASE = "8.3.6"
$env:GHCR_PAT    = "<your-token>"
.\scripts\mirror-to-ghcr.ps1
```

```bash
# Bash
GHCR_OWNER=ia-tgoetz IGN_RELEASE=8.3.6 GHCR_PAT=<your-token> \
  bash scripts/mirror-to-ghcr.sh
```

### 1.4 Make the GHCR package private

Default visibility is public. Lock it down:

<https://github.com/users/ia-tgoetz/packages/container/ignition/settings> → **Change visibility** → **Private**

Then under **Manage Actions access**, add this repository so the workflow's `GITHUB_TOKEN` can pull.

---

## Phase 2 — Configure GitHub repository

### 2.1 Add Secrets

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Value |
|---|---|
| `GATEWAY_ADMIN_USERNAME` | Initial admin username for the gateway |
| `GATEWAY_ADMIN_PASSWORD` | Initial admin password (use a strong one) |
| `IGN_NAME` *(optional)* | Override the gateway display name. If unset, the IPC's hostname is used. |
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

Clone the repo, then:

```bash
git clone https://github.com/ia-tgoetz/DeploymentGitActions.git
cd DeploymentGitActions
sudo bash scripts/provision-runner.sh <one-time-token>
```

That's it. The script:

| Step | What it does |
|---|---|
| 1 | Installs `curl`, `git`, `jq`, `ufw`, `ca-certificates` |
| 2 | Installs Docker via `get.docker.com` (skips if already present) |
| 3 | Creates the `github-runner` system user (no login shell, in `docker` group) |
| 4 | Configures UFW: allows `OpenSSH`, then opens Ignition ports `8088`, `8043`, `8060` |
| 5 | Downloads the latest GitHub Actions runner into `/opt/actions-runner` |
| 6 | Registers it with GitHub using your token, name = hostname, labels = `self-hosted,Linux,X64,ipc` |
| 7 | Installs and starts the systemd service running as `github-runner` |
| 8 | Pre-creates `/opt/ignition-images/` for the optional tar fallback |

After it completes, verify in GitHub: `Settings → Actions → Runners` — the runner should appear as **Idle** with the IPC's existing hostname.

> **The script does not change the IPC's hostname.** It reads `$(hostname)` and reuses it as both the runner name and (at deploy time) the Ignition gateway name. Set the hostname through your normal IPC provisioning before running this script (Proxmox template, cloud-init, `hostnamectl`, whatever you prefer).
>
> To override the runner name without changing the host's hostname:
> ```bash
> sudo bash scripts/provision-runner.sh <token> custom-runner-name
> ```

### 3.3 Fetch third-party modules

Third-party `.modl` files are baked into a derived Docker image at build time (the IA-recommended pattern for 8.3 — see [docker-image-examples](https://www.docs.inductiveautomation.com/docs/8.3/platform/docker-image/docker-image-examples)). The repo's `Dockerfile` extends the GHCR base image and copies `services/modules/*.modl` into `/usr/local/bin/ignition/user-lib/modules/`, where Ignition loads them automatically on every gateway start.

The `.modl` binaries themselves are gitignored — they live alongside the repo on each IPC, not in Git. The deploy workflow runs `fetch-modules.sh` automatically before each build, but you can also run it manually:

```bash
cd ~/path/to/repo
bash scripts/fetch-modules.sh   # or .\scripts\fetch-modules.ps1 on Windows
```

Currently configured: **Cirrus Link MQTT Transmission 5.0.3** (module ID `com.cirruslink.mqtt.transmission.gateway`).

To add another module:

1. Edit the `MODULES` list in `scripts/fetch-modules.sh` / `.ps1`
2. Append the module ID (Java package style — find it in the gateway's web UI or the module's documentation) to `GATEWAY_MODULES_ACCEPTED`, `ACCEPT_MODULE_LICENSES`, and `ACCEPT_MODULE_CERTS` in `.env.example` and the workflow's `.env` write step
3. Push to `main` — the runner re-fetches, rebuilds the derived image, and redeploys

The build is fast: one `COPY` layer over the cached base. It only re-runs when `services/modules/` actually changes.

### 3.4 (Optional) Pre-stage the image tar for air-gapped fallback

If the IPC may temporarily lose internet, pre-stage a tar so the deploy still works:

```bash
sudo mkdir -p /opt/ignition-images

# From a workstation with internet:
docker pull ghcr.io/ia-tgoetz/ignition:8.3.6
docker save ghcr.io/ia-tgoetz/ignition:8.3.6 -o ignition-8.3.6.tar
# scp ignition-8.3.6.tar to the IPC, then:
sudo mv ignition-8.3.6.tar /opt/ignition-images/
```

`scripts/load-image.sh` tries GHCR first and falls back to this tar automatically.

---

## Phase 4 — First deployment

Push any change to `main` (or use **Actions → Deploy Ignition Edge → Run workflow**). The runner will:

1. Verify Docker access
2. Log in to GHCR using the workflow's `GITHUB_TOKEN`
3. Pull the image (or load from tar fallback)
4. Write a runtime `.env` from Secrets + repo defaults
5. `docker compose down --timeout 60 && up -d`
6. Poll `http://localhost:8088/StatusPing` until it returns `RUNNING`
7. Clean up the runtime `.env`

Open `http://<ipc-ip>:8088` in a browser to verify. Log in with the admin credentials from the Secrets.

---

## Phase 5 — Configure the Gateway Network connection

GAN settings live in Ignition's internal database, not in the file-based config, so this step happens once after the central gateway address is known.

On the IPC:

```bash
cd ~/path/to/repo

# Make sure config/central-gateway.env is filled in and committed:
cat config/central-gateway.env

# Source the runtime .env so admin creds are available:
set -a; source .env; set +a

bash scripts/configure-gan.sh
```

Verify in the gateway UI: `http://<ipc-ip>:8088/web/config/networking.ganconfig`.

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

### Bumping the Ignition version

1. Update `IGN_RELEASE` in your local `.env`.
2. Mirror the new tag to GHCR — re-run `.\run-mirror.ps1` (Windows) or `bash run-mirror.sh` (Linux/macOS).
3. Update `IGN_RELEASE` in `.github/workflows/deploy.yml` and `.env.example`.
4. Commit and push to `main`. Every IPC will roll forward on its next deploy.

### Rolling back

Re-tag a known-good version in GHCR or revert the `main` branch commit that bumped the version. Push, and every IPC rolls back.

### Changing the central gateway address

1. Edit `config/central-gateway.env`, commit, push.
2. SSH to each affected IPC and re-run `bash scripts/configure-gan.sh`.

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

If the agent isn't running (no API key) but you want to capture a lesson — like the one from the `-h`/`-s` restart-loop incident — append it to `scripts/memory.md` directly. Use the same format the agent uses, so when the agent does come online its `<memory>` context stays consistent:

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

**Runner shows offline in GitHub UI**
```bash
sudo ~/actions-runner/svc.sh status
sudo journalctl -u actions.runner.* -f
```

**Container won't pull from GHCR**
- Verify the package is shared with the repo: GHCR package settings → **Manage Actions access** → add the repo.
- Verify `GITHUB_TOKEN` has `packages:read` (granted via `permissions:` block in the workflow).

**Container starts but health check fails**
```bash
docker logs ignition-edge --tail 200
docker exec -it ignition-edge curl -sf http://localhost:8088/StatusPing
```

**File ownership issues on bind mounts**
Set `IGN_UID` / `IGN_GID` in `.env` to match the host user that owns `services/`.

**PowerShell complains about `VAR=value` syntax**
That's bash syntax. On Windows use `$env:VAR = "value"` on its own line, then run the script. See Phase 1.3.

**Need to wipe state and start fresh**
```bash
docker compose down -v   # -v removes the named volumes (DB, modules, logs)
```
