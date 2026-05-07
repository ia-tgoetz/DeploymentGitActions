# Ignition 8.3 Edge — Automated Deployment

Automated deployment and configuration sync for Inductive Automation's Ignition 8.3 Edge on field Industrial PCs (IPCs), driven by GitHub Actions and a private GHCR-hosted Docker image.

## How it works

1. **Image source:** the Ignition image is mirrored from Docker Hub into your private GitHub Container Registry once. IPCs only ever pull from `ghcr.io/<owner>/ignition:<version>`, never from public registries.
2. **Runner:** each IPC runs a self-hosted GitHub Actions runner registered against this repo.
3. **Trigger:** any push to `main` triggers `.github/workflows/deploy.yml`.
4. **Sync:** the runner pulls the latest repo, writes the MQTT CA cert from a Secret, writes a runtime `.env`, then `docker compose down && up -d` with a health-check wait.
5. **Config-as-code:** Ignition projects and the file-based VCS config live in `services/projects/` and `services/config/resources/`, bind-mounted into the container.

---

## Repository structure

```
.
├── .github/workflows/deploy.yml    # CI/CD workflow — runs on every push to main
├── docker-compose.yml              # Production: Ignition Edge only
├── docker-compose.test.yml         # Adds Mosquitto + central GW for local testing
├── .env.example                    # Template — copy to .env per environment
├── config/
│   └── central-gateway.env         # GAN target details (per site, committed)
├── services/
│   ├── config/resources/           # Ignition VCS config (file-based gateway config)
│   └── projects/                   # Ignition projects
├── scripts/
│   ├── mirror-to-ghcr.sh           # One-time: mirror IA's image into your GHCR
│   ├── load-image.sh               # IPC: ensure image is available (GHCR or tar)
│   ├── health-check.sh             # IPC: poll /StatusPing until RUNNING
│   └── configure-gan.sh            # IPC: one-time GAN connection setup
├── test/mosquitto/config/          # Mosquitto config for the local test stack
└── certs/                          # MQTT CA cert (gitignored, written by deploy.yml)
```

---

## Prerequisites

- A GitHub repo with **Branch protection on `main`** enabled (the runner has Docker access — protect what executes on it)
- GHCR enabled on your account/org
- One Linux IPC (Ubuntu Server 22.04 or 24.04 LTS recommended) with network access to `github.com` and `ghcr.io`
- Inductive Automation Docker image access (no special credentials required for the public Docker Hub image we mirror)

---

## Phase 1 — One-time setup on a workstation

This phase mirrors IA's official image into your GHCR. Done once per Ignition version bump.

### 1.1 Create a GitHub Personal Access Token

Go to <https://github.com/settings/tokens/new> and create a classic token with these scopes:
- `write:packages`
- `read:packages`
- `repo` (auto-selected)

Save the token somewhere safe.

### 1.2 Mirror the image

From any machine with Docker and internet access:

```bash
git clone https://github.com/ia-tgoetz/DeploymentGitActions.git
cd DeploymentGitActions

GHCR_OWNER=ia-tgoetz \
IGN_RELEASE=8.3.6 \
GHCR_PAT=<your-token> \
bash scripts/mirror-to-ghcr.sh
```

### 1.3 Make the GHCR package private

Default visibility is public. Lock it down:

<https://github.com/users/ia-tgoetz/packages/container/ignition/settings> → **Change visibility** → **Private**

---

## Phase 2 — Configure GitHub repository

### 2.1 Add Secrets

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Value |
|---|---|
| `GATEWAY_ADMIN_USERNAME` | Initial admin username for the gateway |
| `GATEWAY_ADMIN_PASSWORD` | Initial admin password (use a strong one) |
| `IGN_NAME` | Gateway display name (e.g. `edge-site-dallas-01`) |
| `MQTT_CA_CERT` | Full PEM contents of the Chariot CA cert (paste `-----BEGIN CERTIFICATE-----` through `-----END CERTIFICATE-----`) |

`GITHUB_TOKEN` is auto-provided by GitHub Actions and is what the workflow uses to authenticate to GHCR — no extra secret needed.

### 2.2 (Recommended) Enable branch protection on `main`

`Settings → Branches → Add rule` for `main`:
- Require pull request before merging
- Require status checks (once you add any)
- Restrict who can push

The self-hosted runner executes whatever's in `main` with Docker root on the IPC. Treat `main` like production.

### 2.3 Per-site config

Edit `config/central-gateway.env` and fill in the central gateway details for the site this IPC will join, then commit. (If sites differ, use a branch per site or environment-specific config files.)

---

## Phase 3 — Provision the IPC

These steps run on the Linux IPC itself.

### 3.1 Install Docker

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
docker run --rm hello-world
```

### 3.2 Register the GitHub Actions runner

In the GitHub repo: `Settings → Actions → Runners → New self-hosted runner → Linux x64`

GitHub will display a one-time token and the exact commands. Run them on the IPC. They look like:

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64-<version>.tar.gz -L \
  https://github.com/actions/runner/releases/download/v<version>/actions-runner-linux-x64-<version>.tar.gz
tar xzf actions-runner-linux-x64-<version>.tar.gz
./config.sh \
  --url https://github.com/ia-tgoetz/DeploymentGitActions \
  --token <one-time-token>
```

Install as a systemd service so it survives reboots:

```bash
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

### 3.3 (Optional) Pre-stage the image tar for air-gapped fallback

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
4. Write `certs/ca.crt` from the `MQTT_CA_CERT` Secret
5. Write a runtime `.env` from Secrets + repo defaults
6. `docker compose down --timeout 60 && up -d`
7. Poll `http://localhost:8088/StatusPing` until it returns `RUNNING`
8. Clean up the runtime `.env` and cert file

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

A full local stack (Edge + Mosquitto + a central gateway container) is in `docker-compose.test.yml`:

```bash
cp .env.example .env
# Fill in GATEWAY_ADMIN_USERNAME / PASSWORD at minimum

docker compose -f docker-compose.yml -f docker-compose.test.yml up -d
```

| Service | URL |
|---|---|
| Ignition Edge | <http://localhost:8088> |
| Central Ignition GW | <http://localhost:9088> |
| Mosquitto plaintext | `mqtt://localhost:1883` |
| Mosquitto TLS | `mqtts://localhost:8883` |

Tear down:

```bash
docker compose -f docker-compose.yml -f docker-compose.test.yml down -v
```

---

## Operations

### Bumping the Ignition version

1. Mirror the new tag to GHCR: re-run `scripts/mirror-to-ghcr.sh` with the new `IGN_RELEASE`.
2. Update `IGN_RELEASE` in `.github/workflows/deploy.yml` and `.env.example`.
3. Commit and push to `main`. Every IPC will roll forward on its next deploy.

### Rolling back

Re-tag a known-good version in GHCR or revert the `main` branch commit that bumped the version. Push, and every IPC rolls back.

### Changing the central gateway address

1. Edit `config/central-gateway.env`, commit, push.
2. SSH to each affected IPC and re-run `bash scripts/configure-gan.sh`.

### Updating MQTT cert

1. Update the `MQTT_CA_CERT` Secret in GitHub.
2. Push any commit to `main` to trigger a redeploy. The cert is rewritten at every deploy.

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

**Need to wipe state and start fresh**
```bash
docker compose down -v   # -v removes the named volumes (DB, modules, logs)
```
