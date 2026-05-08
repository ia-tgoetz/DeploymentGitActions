# Ignition 8.3 Edge — Automated Deployment

Automated deployment and configuration sync for Inductive Automation's Ignition 8.3 Edge on field Industrial PCs (IPCs), driven by GitHub Actions and a private GHCR-hosted Docker image with third-party modules baked in.

## How it works

1. **Image source:** a **derived Edge image** is built once from `build/edgeGwBuild/Dockerfile` (extends IA's base image and `COPY`s third-party `.modl` files into `user-lib/modules`). It's pushed to your private GHCR as `ghcr.io/<owner>/ignition-edge:<version>`. IPCs only ever pull from there — never from public registries, and never with a runtime `.modl` mount.
2. **Runner:** each IPC runs a self-hosted GitHub Actions runner registered against this repo (provisioned in one shot via `scripts/provision-runner.sh`).
3. **Trigger:** any push to `main` triggers `.github/workflows/deploy.yml`.
4. **Sync:** the runner pulls the derived image, writes a runtime `.env` from Secrets + the IPC hostname, then `docker compose down && up -d` with a health-check wait.
5. **Config-as-code:** Ignition projects and the file-based VCS config live in `services/projects/` and `services/config/resources/`, bind-mounted into the container.
6. **Gateway naming:** each IPC's Ignition gateway name automatically inherits the host's `hostname`, so the central GW's GAN view shows fleet members by IPC identity. Override with the `IGN_NAME` repo Secret if you need a custom name.

---

## Repository structure

```
.
├── .github/workflows/deploy.yml    # CI/CD workflow — runs on every push to main
├── docker-compose.yml              # Production: Ignition Edge only
├── docker-compose.test.yml         # Adds a central GW container for local GAN testing
├── .env.example                    # Template — copy to .env per environment
├── build/
│   └── edgeGwBuild/
│       ├── Dockerfile              # Derived Edge image (base + .modl in user-lib/modules)
│       └── .gitignore              # Excludes .modl binaries
├── config/
│   └── central-gateway.env         # GAN target details (per site, committed)
├── services/
│   ├── config/resources/           # Ignition VCS config (file-based gateway config)
│   └── projects/                   # Ignition projects
├── run-push-edge.ps1               # Wrapper: loads .env, pushes the prebuilt Edge tar to GHCR (Windows)
├── run-push-edge.sh                # Wrapper: loads .env, pushes the prebuilt Edge tar to GHCR (Linux/macOS)
├── run-mirror.ps1                  # Wrapper: mirrors IA's BASE image into GHCR (rarely needed)
├── run-mirror.sh                   # Wrapper: mirrors IA's BASE image into GHCR (rarely needed)
└── scripts/
    ├── push-image-to-ghcr.ps1      # Push a derived image (tar or local) to GHCR (Windows)
    ├── push-image-to-ghcr.sh       # Push a derived image (tar or local) to GHCR (Linux/macOS)
    ├── mirror-to-ghcr.ps1          # Mirror IA's base image into GHCR (Windows) — only needed if pulling base directly
    ├── mirror-to-ghcr.sh           # Mirror IA's base image into GHCR (Linux/macOS) — only needed if pulling base directly
    ├── fetch-modules.ps1           # Optional helper: download .modl files into build/edgeGwBuild/ before a build
    ├── fetch-modules.sh            # Optional helper: download .modl files into build/edgeGwBuild/ before a build
    ├── provision-runner.sh         # One-shot: full IPC provisioning (Docker, UFW, runner)
    ├── load-image.sh               # IPC: ensure derived image is available (GHCR or tar)
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

## Phase 1 — Build and push the derived Edge image

This phase is done **once per module-version change** (not every deploy). It runs on a workstation, not the IPC. The result is a private image at `ghcr.io/<owner>/ignition-edge:<version>` with all third-party `.modl` files baked into `user-lib/modules`.

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
IGN_RELEASE=8.3.6
```

`.env` is gitignored, so the PAT stays local.

### 1.3 Stage the `.modl` files

Place each third-party `.modl` you want baked in alongside `build/edgeGwBuild/Dockerfile`:

```powershell
copy C:\path\to\MQTT-Transmission-signed.modl build\edgeGwBuild\
```

The `.modl` binaries are gitignored — they live alongside the build context but are never committed.

### 1.4 Build the derived image

From the repo root:

```powershell
docker build `
  -t edge-with-transmission:8.3.6 `
  --build-arg IGNITION_VERSION=8.3.6 `
  .\build\edgeGwBuild
```

```bash
docker build \
  -t edge-with-transmission:8.3.6 \
  --build-arg IGNITION_VERSION=8.3.6 \
  ./build/edgeGwBuild
```

You can also save it as a tar (useful if you want to inspect it before pushing, or distribute it sideband to air-gapped sites):

```bash
docker save edge-with-transmission:8.3.6 -o build/edgeGwBuild/edgeWithTransmission.tar
```

### 1.5 Push to GHCR

From the repo root:

```powershell
.\run-push-edge.ps1            # pushes build\edgeGwBuild\edgeWithTransmission.tar
```

```bash
bash run-push-edge.sh           # pushes build/edgeGwBuild/edgeWithTransmission.tar
```

The wrapper loads `.env`, then calls `scripts/push-image-to-ghcr.{ps1,sh}` against the staged tar with destination tag `ignition-edge:${IGN_RELEASE}`. It prints the GHCR URL when finished.

If you'd rather skip the tar and push the local image directly:

```bash
GHCR_OWNER=ia-tgoetz GHCR_PAT=<token> \
  bash scripts/push-image-to-ghcr.sh edge-with-transmission:8.3.6 ignition-edge:8.3.6
```

### 1.6 Make the new GHCR package accessible

**One time only**, after the first push of a new package:

1. Visit <https://github.com/users/ia-tgoetz/packages/container/ignition-edge/settings>
2. **Change visibility → Private**
3. **Manage Actions access → Add Repository → DeploymentGitActions → Read**

Without step 3, the workflow's auto-injected `GITHUB_TOKEN` will 403 when trying to pull.

---

## Phase 2 — Configure the GitHub repository

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

Clone the repo on the IPC, then:

```bash
git clone https://github.com/ia-tgoetz/DeploymentGitActions.git
cd DeploymentGitActions
sudo bash scripts/provision-runner.sh <one-time-token>
```

That's it. The script:

| Step | What it does |
|---|---|
| 1 | Installs `curl`, `git`, `jq`, `ufw`, `ca-certificates`, `python3` + `python3-venv` |
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

### 3.3 (Optional) Pre-stage the image tar for air-gapped fallback

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

Push any change to `main` (or use **Actions → Deploy Ignition Edge → Run workflow**). The runner will:

1. Verify Docker access
2. Log in to GHCR using the workflow's `GITHUB_TOKEN`
3. Pull `ghcr.io/<owner>/ignition-edge:<version>` (or load from tar fallback)
4. Write a runtime `.env` from Secrets + repo defaults
5. `docker compose down --timeout 60 && up -d`
6. Poll `http://localhost:8088/StatusPing` until it returns `RUNNING`
7. Clean up the runtime `.env`

Open `http://<ipc-ip>:8088` in a browser to verify. Log in with the admin credentials from the Secrets. Check **Config → Modules** — Cirrus Link MQTT Transmission should appear as `Trial / ACTIVE`.

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

### Adding or upgrading a third-party module

1. Place the new `.modl` in `build/edgeGwBuild/`
2. Update `build/edgeGwBuild/Dockerfile` if you're adding a new `.modl` (add a `COPY` line)
3. Append the module ID to `ACCEPT_MODULE_LICENSES` and `ACCEPT_MODULE_CERTS` in `.env.example` and `.github/workflows/deploy.yml`'s `.env` write step

   > Get the canonical module ID from the `.modl` itself:
   > ```bash
   > python3 -c "import zipfile; print(zipfile.ZipFile('build/edgeGwBuild/<file>.modl').read('module.xml').decode())"
   > ```
   > The `<id>` element is what `ACCEPT_MODULE_*` matches against — not the display name, not the resource-folder path.

4. Rebuild and re-push (Phase 1.4 + 1.5)
5. Bump the image tag if you want versioning per module-version (e.g. `IGN_RELEASE=8.3.6-mqtt-5.0.4`), then update `IGN_RELEASE` in `.env.example` and `deploy.yml`
6. Commit and push to `main` — every IPC pulls the new image on its next deploy

### Bumping the Ignition base version

1. Update the `FROM inductiveautomation/ignition:<version>` line in `build/edgeGwBuild/Dockerfile`
2. Rebuild and push the derived image (Phase 1.4 + 1.5) with the new `IGN_RELEASE`
3. Update `IGN_RELEASE` in `.env.example` and `.github/workflows/deploy.yml`
4. Commit and push to `main`. Every IPC will roll forward on its next deploy.

### Rolling back

Re-tag a known-good image in GHCR (or change `IGN_RELEASE` in `deploy.yml` to a previous tag), commit, push. Every IPC rolls back on the next deploy.

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
