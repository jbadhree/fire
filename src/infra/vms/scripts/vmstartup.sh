#!/bin/bash
# Startup script: runs on EVERY boot (GCP default).
# Placeholders replaced by Pulumi: __PROJECT_ID__, __OPENROUTER_SECRET_NAME__,
#   __SLACK_BOT_SECRET_NAME__, __SLACK_APP_SECRET_NAME__
# Debug: cat /tmp/openclaw-startup.log  OR  gcloud compute instances get-serial-port-output

set -e

STARTUP_LOG="/tmp/openclaw-startup.log"
exec > >(tee -a "$STARTUP_LOG") 2>&1

log() { echo "[openclaw-startup] $(date -Iseconds) $*"; }
trap 'log "FAILED at line $LINENO"; exit 1' ERR

PROJECT_ID="__PROJECT_ID__"
OPENROUTER_SECRET_NAME="__OPENROUTER_SECRET_NAME__"
SLACK_BOT_SECRET_NAME="__SLACK_BOT_SECRET_NAME__"
SLACK_APP_SECRET_NAME="__SLACK_APP_SECRET_NAME__"
SLACK_ALLOWED_USER_IDS_SECRET_NAME="__SLACK_ALLOWED_USER_IDS_SECRET_NAME__"

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/var/lib/openclaw"
CONFIG_DIR="${OPENCLAW_HOME}/.openclaw"
CONFIG_FILE="${CONFIG_DIR}/openclaw.json"
INITIALIZED_MARKER="${OPENCLAW_HOME}/.initialized"

export DEBIAN_FRONTEND=noninteractive

log "Starting OpenClaw VM startup script (boot)."

# ── Install once ────────────────────────────────────────────────────────────
# On stop/start the disk persists, so we skip the heavy install on subsequent boots.
if [ ! -f "${INITIALIZED_MARKER}" ]; then
  log "First boot: installing packages, Node.js 22, and OpenClaw..."

  apt-get update -qq
  apt-get install -y -qq curl git ca-certificates

  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs

  # Create openclaw user
  if ! id -u "${OPENCLAW_USER}" &>/dev/null; then
    useradd -m -r -s /bin/bash -d "${OPENCLAW_HOME}" "${OPENCLAW_USER}"
  fi
  mkdir -p "${CONFIG_DIR}/logs"
  chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${OPENCLAW_HOME}"

  # Install OpenClaw globally (https://docs.openclaw.ai/install)
  npm install -g openclaw@latest

  # Write systemd unit
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
Environment=OPENCLAW_CONFIG_PATH=/var/lib/openclaw/.openclaw/openclaw.json
Environment=NODE_OPTIONS=--max-old-space-size=2048
ExecStart=/usr/bin/npx openclaw gateway --port 18789 --allow-unconfigured
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD

  systemctl daemon-reload
  systemctl enable openclaw

  touch "${INITIALIZED_MARKER}"
  log "First-boot install complete."
else
  log "Already initialized — skipping package/Node/OpenClaw install."
fi

# ── Fetch secrets and write config (runs on every boot) ─────────────────────
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

# Fetch Slack tokens if secret names are configured (non-empty placeholders)
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

# ── Write openclaw.json (merge, preserving pairing data and auth tokens) ─────
log "Updating OpenClaw config..."
mkdir -p "${CONFIG_DIR}/logs"
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${OPENCLAW_HOME}"

export OPENROUTER_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USER_IDS CONFIG_FILE
python3 - << 'PYEOF'
import json, os

config_file = os.environ["CONFIG_FILE"]
openrouter_key = os.environ["OPENROUTER_KEY"]
slack_bot_token = os.environ.get("SLACK_BOT_TOKEN", "")
slack_app_token = os.environ.get("SLACK_APP_TOKEN", "")
slack_allowed_ids_raw = os.environ.get("SLACK_ALLOWED_USER_IDS", "")

# Read existing config so pairing data, auth tokens, etc. are preserved.
try:
    with open(config_file) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

# Update only the fields managed by this script; leave everything else untouched.
config.setdefault("gateway", {})["mode"] = "local"
config.setdefault("env", {})["OPENROUTER_API_KEY"] = openrouter_key
config.setdefault("agents", {}).setdefault("defaults", {}).setdefault("model", {})["primary"] = \
    "openrouter/anthropic/claude-sonnet-4-5"

if slack_bot_token and slack_app_token:
    slack_cfg = config.setdefault("channels", {}).setdefault("slack", {})
    slack_cfg.update({
        "enabled": True,
        "mode": "socket",
        "botToken": slack_bot_token,
        "appToken": slack_app_token,
    })
    # Skip pairing: allowlist specific Slack user IDs so they can DM without approval.
    if slack_allowed_ids_raw:
        allowed = [u.strip() for u in slack_allowed_ids_raw.split(",") if u.strip()]
        slack_cfg["dmPolicy"] = "allowlist"
        slack_cfg["allowFrom"] = allowed

with open(config_file, "w") as f:
    json.dump(config, f, indent=2)
PYEOF

chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${CONFIG_FILE}"
chmod 600 "${CONFIG_FILE}"
unset OPENROUTER_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN

# ── Start / restart service ──────────────────────────────────────────────────
log "Starting OpenClaw gateway..."
systemctl restart openclaw

log "Startup script finished. Gateway running on port 18789."
