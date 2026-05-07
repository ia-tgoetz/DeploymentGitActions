#!/usr/bin/env bash
# One-shot IPC provisioning for the Ignition Edge deployment pipeline.
#
# Takes a fresh Ubuntu Server box from zero to "registered runner ready to
# deploy" — installs Docker, opens Ignition firewall ports, creates a
# dedicated github-runner system user, downloads/configures the runner, and
# starts it as a systemd service.
#
# Idempotent: safe to re-run. Skips steps that are already complete.
#
# Usage:
#   sudo bash scripts/provision-runner.sh <github-actions-token> [runner-name]
#
# Get the token from:
#   https://github.com/ia-tgoetz/DeploymentGitActions/settings/actions/runners/new
# (token expires ~1 hour, generate fresh if stale).

set -euo pipefail

# ----- Configuration ---------------------------------------------------------
REPO_URL="https://github.com/ia-tgoetz/DeploymentGitActions"
RUNNER_USER="github-runner"
RUNNER_HOME="/opt/actions-runner"
IGNITION_IMAGES_DIR="/opt/ignition-images"
IGNITION_PORTS=(8088 8043 8060)
RUNNER_LABELS="self-hosted,Linux,X64,ipc"

# ----- Args & sanity ---------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: sudo bash $0 <github-actions-token> [runner-name]" >&2
  echo "Token: ${REPO_URL}/settings/actions/runners/new" >&2
  exit 1
fi
TOKEN="$1"
RUNNER_NAME="${2:-$(hostname)}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (use sudo)." >&2
  exit 1
fi

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

log "Provisioning $(hostname) for $REPO_URL"
log "Runner name: $RUNNER_NAME    Service user: $RUNNER_USER"

# ----- 1. System packages ----------------------------------------------------
log "Installing system packages (curl, git, jq, ufw, ca-certificates)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git jq ufw ca-certificates

# ----- 2. Docker -------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  log "Installing Docker via get.docker.com..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker already installed: $(docker --version)"
fi
systemctl enable --now docker

# ----- 3. Service user -------------------------------------------------------
if ! id "$RUNNER_USER" &>/dev/null; then
  log "Creating system user $RUNNER_USER..."
  useradd --system --shell /usr/sbin/nologin --home-dir "$RUNNER_HOME" "$RUNNER_USER"
else
  log "User $RUNNER_USER already exists."
fi

mkdir -p "$RUNNER_HOME"
chown "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

# Ensure runner user can talk to Docker
if ! id -nG "$RUNNER_USER" | tr ' ' '\n' | grep -qx docker; then
  log "Adding $RUNNER_USER to docker group..."
  usermod -aG docker "$RUNNER_USER"
fi

# ----- 4. Firewall (UFW) -----------------------------------------------------
log "Configuring UFW (SSH first to avoid lockout, then Ignition ports)..."
ufw allow OpenSSH
for port in "${IGNITION_PORTS[@]}"; do
  ufw allow "${port}/tcp" comment "Ignition ${port}" || true
done
ufw --force enable
ufw reload

# ----- 5. Runner binaries ----------------------------------------------------
if [[ ! -x "$RUNNER_HOME/config.sh" ]]; then
  log "Fetching latest GitHub Actions runner release..."
  RUNNER_VERSION=$(curl -sL https://api.github.com/repos/actions/runner/releases/latest \
    | jq -r .tag_name | sed 's/^v//')
  RUNNER_TAR="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  log "Downloading runner v${RUNNER_VERSION}..."
  cd "$RUNNER_HOME"
  curl -sL -o "$RUNNER_TAR" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TAR}"
  tar xzf "$RUNNER_TAR"
  rm "$RUNNER_TAR"
  chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
else
  log "Runner binaries already present in $RUNNER_HOME."
fi

# ----- 6. Register runner ----------------------------------------------------
if [[ ! -f "$RUNNER_HOME/.runner" ]]; then
  log "Registering runner with GitHub as '$RUNNER_NAME'..."
  cd "$RUNNER_HOME"
  sudo -u "$RUNNER_USER" ./config.sh \
    --url "$REPO_URL" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$RUNNER_LABELS" \
    --work _work \
    --unattended \
    --replace
else
  EXISTING_NAME=$(jq -r .agentName "$RUNNER_HOME/.runner" 2>/dev/null || echo unknown)
  log "Runner already registered as '$EXISTING_NAME'."
  log "  To re-register with a new token: rm $RUNNER_HOME/.runner && re-run."
fi

# ----- 7. Systemd service ----------------------------------------------------
log "Installing systemd service..."
cd "$RUNNER_HOME"
# Clean up any prior install so the new one inherits the docker group
if systemctl list-units --all 'actions.runner.*' --no-legend | grep -q .; then
  ./svc.sh stop || true
  ./svc.sh uninstall || true
fi
./svc.sh install "$RUNNER_USER"
./svc.sh start

# ----- 8. Pre-stage image dir (for optional tar fallback) --------------------
log "Creating ${IGNITION_IMAGES_DIR}/ for optional air-gapped image tars..."
mkdir -p "$IGNITION_IMAGES_DIR"
chown "$RUNNER_USER:$RUNNER_USER" "$IGNITION_IMAGES_DIR"

# ----- Done ------------------------------------------------------------------
log "Provisioning complete."
echo
./svc.sh status || true
echo
cat <<EOF
-------------------------------------------------------------------------------
Runner: $RUNNER_NAME
Verify in GitHub UI:
  $REPO_URL/settings/actions/runners
  (should show '$RUNNER_NAME' as Idle)

Open ports (Ignition + SSH):
  $(ufw status numbered | sed 's/^/  /')

Tail runner logs:
  sudo journalctl -u 'actions.runner.*' -f

Re-run this script anytime — it's idempotent.
-------------------------------------------------------------------------------
EOF
