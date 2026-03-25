#!/bin/bash
# Startup script: runs on EVERY boot (GCP default).
# Placeholders replaced by Pulumi: __PROJECT_ID__, __GCS_BUCKET_NAME__,
#   __OPENROUTER_SECRET_NAME__, __SLACK_BOT_SECRET_NAME__,
#   __SLACK_APP_SECRET_NAME__, __SLACK_ALLOWED_USER_IDS_SECRET_NAME__,
#   __SKILLS_REPO_URL__, __NODE_MAJOR_VERSION__, __OPENCLAW_VERSION__
# Debug: cat /tmp/openclaw-startup.log  OR  gcloud compute instances get-serial-port-output

set -e

STARTUP_LOG="/tmp/openclaw-startup.log"
exec > >(tee -a "$STARTUP_LOG") 2>&1

log() { echo "[openclaw-startup] $(date -Iseconds) $*"; }
trap 'log "FAILED at line $LINENO"; exit 1' ERR

# ── Pulumi-injected values (all placeholders live here) ──────────────────────
PROJECT_ID="__PROJECT_ID__"
GCS_BUCKET_NAME="__GCS_BUCKET_NAME__"
OPENROUTER_SECRET_NAME="__OPENROUTER_SECRET_NAME__"
SLACK_BOT_SECRET_NAME="__SLACK_BOT_SECRET_NAME__"
SLACK_APP_SECRET_NAME="__SLACK_APP_SECRET_NAME__"
SLACK_ALLOWED_USER_IDS_SECRET_NAME="__SLACK_ALLOWED_USER_IDS_SECRET_NAME__"
SKILLS_REPO_URL="__SKILLS_REPO_URL__"
NODE_MAJOR="__NODE_MAJOR_VERSION__"
OPENCLAW_VERSION="__OPENCLAW_VERSION__"
# ── Tailscale (disabled — uncomment placeholder + index.ts to re-enable) ─────
# TAILSCALE_AUTH_KEY_SECRET_NAME="__TAILSCALE_AUTH_KEY_SECRET_NAME__"

# ── Derived variables ─────────────────────────────────────────────────────────
OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/var/lib/openclaw"
GCS_MOUNT_DIR="${OPENCLAW_HOME}/gcs"
# All OpenClaw data lives here on GCS — persists across VM recreates.
# The startup script symlinks ~/.openclaw → this dir so OpenClaw writes here too.
OPENCLAW_CONFIG_DIR="${GCS_MOUNT_DIR}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"
# fire-skills on local disk — git operations are faster off GCS.
FIRE_SKILLS_DIR="${OPENCLAW_HOME}/fire-skills"
INITIALIZED_MARKER="${OPENCLAW_HOME}/.initialized"

export DEBIAN_FRONTEND=noninteractive

log "Starting OpenClaw VM startup script (boot)."

# ── Install once ─────────────────────────────────────────────────────────────
# On stop/start the disk persists, so we skip the heavy install on subsequent boots.
if [ ! -f "${INITIALIZED_MARKER}" ]; then
  log "First boot: installing packages, Node.js ${NODE_MAJOR}, and OpenClaw ${OPENCLAW_VERSION} (~5-10 min)..."

  apt-get update -qq
  apt-get install -y -qq curl git ca-certificates

  # ── Node.js + OpenClaw ────────────────────────────────────────────────────
  # Versions pinned via Pulumi config — change in Pulumi.dev.yaml, not here.
  log "Installing Node.js ${NODE_MAJOR}..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -qq nodejs

  log "Installing OpenClaw ${OPENCLAW_VERSION}..."
  npm install -g "openclaw@${OPENCLAW_VERSION}"

  # ── gcsfuse ────────────────────────────────────────────────────────────────
  log "Installing gcsfuse..."
  DISTRO_CODENAME=$(lsb_release -cs)
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/google-cloud-packages.gpg
  echo "deb [signed-by=/usr/share/keyrings/google-cloud-packages.gpg] https://packages.cloud.google.com/apt gcsfuse-${DISTRO_CODENAME} main" \
    > /etc/apt/sources.list.d/gcsfuse.list
  apt-get update -qq
  apt-get install -y -qq gcsfuse fuse
  echo "user_allow_other" >> /etc/fuse.conf

  # ── Create openclaw user ───────────────────────────────────────────────────
  if ! id -u "${OPENCLAW_USER}" &>/dev/null; then
    useradd -m -r -s /bin/bash -d "${OPENCLAW_HOME}" "${OPENCLAW_USER}"
  fi
  getent group fuse || groupadd -r fuse
  usermod -aG fuse "${OPENCLAW_USER}"

  # ── OpenClaw sudoers (restart without password) ───────────────────────────
  # Allows the openclaw user (and skills) to restart the service without a
  # password prompt. Scoped to this one script only.
  cat > /usr/local/bin/restart-openclaw.sh << 'EOF'
#!/bin/bash
systemctl restart openclaw
EOF
  chmod +x /usr/local/bin/restart-openclaw.sh
  echo "${OPENCLAW_USER} ALL=(root) NOPASSWD: /usr/local/bin/restart-openclaw.sh" \
    > /etc/sudoers.d/openclaw-restart
  chmod 0440 /etc/sudoers.d/openclaw-restart

  # ── OpenClaw systemd unit ─────────────────────────────────────────────────
  # Why systemd instead of just running in the background:
  #   - Restart=on-failure: if OpenClaw crashes, systemd revives it automatically.
  #   - Clean shutdown: systemd sends SIGTERM on VM stop so in-flight GCS writes flush.
  #   - Observability: `systemctl status` and `journalctl -u openclaw` work.
  #
  # Why NOT enabled (no systemctl enable):
  #   - On boot, systemd would start it before this startup script runs.
  #   - At that point GCS isn't mounted yet and the config file doesn't exist.
  #   - Instead, the startup script starts it manually after GCS is ready.
  #   - Restart=on-failure still kicks in if it crashes AFTER the initial start.
  cat > /etc/systemd/system/openclaw.service << 'SYSTEMD'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
Environment=HOME=/var/lib/openclaw
# ~/.openclaw is symlinked to GCS by the startup script — all data persists.
Environment=OPENCLAW_CONFIG_PATH=/var/lib/openclaw/.openclaw/openclaw.json
Environment=NODE_OPTIONS=--max-old-space-size=2048
ExecStart=/usr/bin/npx openclaw gateway --port 18789 --allow-unconfigured
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD
  systemctl daemon-reload

  # ── Clone skills registry ─────────────────────────────────────────────────
  # Cloned to local disk (not GCS mount) so git operations are fast and reliable.
  log "Cloning fire-skills registry from ${SKILLS_REPO_URL}..."
  sudo -u "${OPENCLAW_USER}" git clone \
    "${SKILLS_REPO_URL}" \
    "${FIRE_SKILLS_DIR}"
  log "fire-skills cloned."

  # ── Tailscale (disabled — uncomment to re-enable) ─────────────────────────
  # log "Setting up Tailscale..."
  # TAILSCALE_AUTH_KEY=$(fetch_secret "${TAILSCALE_AUTH_KEY_SECRET_NAME}" "tailscale-auth-key")
  # curl -fsSL https://tailscale.com/install.sh | sh
  # tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --ssh

  touch "${INITIALIZED_MARKER}"
  log "First-boot install complete."
else
  log "Already initialized — skipping install."
fi

# ── Pull latest fire-skills (runs on every boot) ─────────────────────────────
# Failure is non-fatal: a stale clone is better than a broken boot.
log "Pulling latest fire-skills..."
if sudo -u "${OPENCLAW_USER}" git -C "${FIRE_SKILLS_DIR}" pull --ff-only 2>/dev/null; then
  log "fire-skills up to date."
else
  log "WARNING: git pull failed — continuing with existing skills."
fi

# ── Fetch secrets (runs on every boot) ───────────────────────────────────────
log "Fetching secrets from Secret Manager..."
ACCESS_TOKEN=$(curl -sS -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['access_token'])")
if [ -z "${ACCESS_TOKEN}" ]; then
  log "ERROR: Failed to obtain access token from metadata server."
  exit 1
fi

fetch_secret() {
  local secret_name="$1"
  local label="$2"
  local response
  response=$(curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${secret_name}/versions/latest:access")
  local value
  value=$(echo "${response}" | python3 -c "
import sys, json, base64
data = json.load(sys.stdin)
if 'error' in data:
    print('ERROR: ' + str(data['error'].get('message', data['error'])), file=sys.stderr)
    sys.exit(1)
print(base64.b64decode(data['payload']['data']).decode('utf-8'), end='')
" 2>/tmp/secret-fetch-error.log)
  if [ $? -ne 0 ] || [ -z "${value}" ]; then
    log "ERROR: Failed to fetch secret '${label}'. $(cat /tmp/secret-fetch-error.log 2>/dev/null)"
    log "Check: secret '${secret_name}' exists in project '${PROJECT_ID}' and VM service account has secretmanager.secretAccessor."
    exit 1
  fi
  echo "${value}"
}

log "Fetching OpenRouter key..."
OPENROUTER_KEY=$(fetch_secret "${OPENROUTER_SECRET_NAME}" "openrouter")

SLACK_BOT_TOKEN=""
SLACK_APP_TOKEN=""
SLACK_ALLOWED_USER_IDS=""
if [ -n "${SLACK_BOT_SECRET_NAME}" ] && [ -n "${SLACK_APP_SECRET_NAME}" ]; then
  log "Fetching Slack tokens..."
  SLACK_BOT_TOKEN=$(fetch_secret "${SLACK_BOT_SECRET_NAME}" "slack-bot-token")
  SLACK_APP_TOKEN=$(fetch_secret "${SLACK_APP_SECRET_NAME}" "slack-app-token")
  if [ -n "${SLACK_ALLOWED_USER_IDS_SECRET_NAME}" ]; then
    log "Fetching Slack allowed user IDs..."
    SLACK_ALLOWED_USER_IDS=$(fetch_secret "${SLACK_ALLOWED_USER_IDS_SECRET_NAME}" "slack-allowed-user-ids")
  fi
fi

# ── Mount GCS bucket ──────────────────────────────────────────────────────────
log "Mounting GCS bucket ${GCS_BUCKET_NAME} at ${GCS_MOUNT_DIR}..."
mkdir -p "${GCS_MOUNT_DIR}"
chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${GCS_MOUNT_DIR}"

if ! mountpoint -q "${GCS_MOUNT_DIR}"; then
  OPENCLAW_UID=$(id -u "${OPENCLAW_USER}")
  OPENCLAW_GID=$(id -g "${OPENCLAW_USER}")
  # Run as root so -o allow_other is permitted without user_allow_other restriction.
  # Files appear owned by the openclaw user via --uid/--gid.
  # gcsfuse 3.x removed --allow-other; the FUSE equivalent is -o allow_other.
  gcsfuse --implicit-dirs \
    --uid="${OPENCLAW_UID}" --gid="${OPENCLAW_GID}" \
    --file-mode=644 --dir-mode=755 \
    -o allow_other \
    "${GCS_BUCKET_NAME}" "${GCS_MOUNT_DIR}"
  log "GCS bucket mounted at ${GCS_MOUNT_DIR}."
else
  log "GCS bucket already mounted."
fi

# ── Symlink ~/.openclaw → GCS so ALL OpenClaw data persists ──────────────────
# OPENCLAW_CONFIG_PATH only controls the config file location. Memory, pairing
# data, session state etc. are written to ~/.openclaw/ by default (local disk).
# Symlinking the whole dir to GCS ensures nothing is lost on destroy/recreate.
sudo -u "${OPENCLAW_USER}" mkdir -p "${OPENCLAW_CONFIG_DIR}/logs"

OPENCLAW_LOCAL_DIR="${OPENCLAW_HOME}/.openclaw"
if [ -d "${OPENCLAW_LOCAL_DIR}" ] && [ ! -L "${OPENCLAW_LOCAL_DIR}" ]; then
  log "Migrating existing ~/.openclaw to GCS..."
  cp -r "${OPENCLAW_LOCAL_DIR}/." "${OPENCLAW_CONFIG_DIR}/" 2>/dev/null || true
  rm -rf "${OPENCLAW_LOCAL_DIR}"
fi
if [ ! -L "${OPENCLAW_LOCAL_DIR}" ]; then
  sudo -u "${OPENCLAW_USER}" ln -sfn "${OPENCLAW_CONFIG_DIR}" "${OPENCLAW_LOCAL_DIR}"
  log "~/.openclaw symlinked to GCS."
fi

# ── Write OpenClaw config (to GCS — persists across VM recreates) ────────────
log "Updating OpenClaw config..."
export OPENROUTER_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USER_IDS OPENCLAW_CONFIG_FILE FIRE_SKILLS_DIR
sudo -E -u "${OPENCLAW_USER}" python3 - << 'PYEOF'
import json, os

config_file = os.environ["OPENCLAW_CONFIG_FILE"]
openrouter_key = os.environ["OPENROUTER_KEY"]
slack_bot_token = os.environ.get("SLACK_BOT_TOKEN", "")
slack_app_token = os.environ.get("SLACK_APP_TOKEN", "")
slack_allowed_ids_raw = os.environ.get("SLACK_ALLOWED_USER_IDS", "")
fire_skills_dir = os.path.join(os.environ["FIRE_SKILLS_DIR"], "skills")

try:
    with open(config_file) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

config.setdefault("gateway", {})["mode"] = "local"
config.setdefault("env", {})["OPENROUTER_API_KEY"] = openrouter_key
config.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})["primary"] = \
    "openrouter/anthropic/claude-sonnet-4-5"

# Wire the fire-skills registry into the skills loader.
# Only appends if not already present so user-added extraDirs are preserved.
extra_dirs = config.setdefault("skills", {}).setdefault("load", {}).setdefault("extraDirs", [])
if fire_skills_dir not in extra_dirs:
    extra_dirs.append(fire_skills_dir)

if slack_bot_token and slack_app_token:
    slack_cfg = config.setdefault("channels", {}).setdefault("slack", {})
    slack_cfg.update({
        "enabled": True,
        "mode": "socket",
        "botToken": slack_bot_token,
        "appToken": slack_app_token,
    })
    if slack_allowed_ids_raw:
        allowed = [u.strip() for u in slack_allowed_ids_raw.split(",") if u.strip()]
        slack_cfg["dmPolicy"] = "allowlist"
        slack_cfg["allowFrom"] = allowed

with open(config_file, "w") as f:
    json.dump(config, f, indent=2)
PYEOF

sudo -u "${OPENCLAW_USER}" chmod 600 "${OPENCLAW_CONFIG_FILE}"
unset OPENROUTER_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USER_IDS

# ── Start OpenClaw ────────────────────────────────────────────────────────────
log "Starting OpenClaw gateway..."
systemctl restart openclaw
OPENCLAW_STATUS=$(systemctl is-active openclaw 2>/dev/null || echo "failed")

log "Startup script finished."
log "  GCS mount:       ${GCS_MOUNT_DIR}  (bucket: ${GCS_BUCKET_NAME})"
log "  OpenClaw config: ${OPENCLAW_CONFIG_FILE}"
log "  OpenClaw status: ${OPENCLAW_STATUS}"
log "  OpenClaw port:   18789"
