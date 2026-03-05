#!/bin/bash
# Startup script: runs when the VM is created.
# Placeholders __PROJECT_ID__ and __OPENROUTER_SECRET_NAME__ are replaced by Pulumi.
# Debug: cat /tmp/openclaw-startup.log after SSH, or use serial console / get-serial-port-output.

set -e

STARTUP_LOG="/tmp/openclaw-startup.log"
exec > >(tee -a "$STARTUP_LOG") 2>&1

log() { echo "[openclaw-startup] $(date -Iseconds) $*"; }
trap 'log "FAILED at line $LINENO"; exit 1' ERR

PROJECT_ID="__PROJECT_ID__"
SECRET_NAME="__OPENROUTER_SECRET_NAME__"
OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/var/lib/openclaw"
CONFIG_DIR="${OPENCLAW_HOME}/.openclaw"
CONFIG_FILE="${CONFIG_DIR}/openclaw.json"

export DEBIAN_FRONTEND=noninteractive

log "Starting OpenClaw VM startup script."

# Install base packages
log "Installing base packages..."
apt-get update -qq
apt-get install -y -qq curl git ca-certificates

# Install Node.js 22 (required by OpenClaw; see https://docs.openclaw.ai/install/node)
log "Installing Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs

# Fetch OpenRouter API key from GCP Secret Manager (VM service account must have secretAccessor)
log "Fetching OpenRouter key from Secret Manager..."
ACCESS_TOKEN=$(curl -sS -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
SECRET_B64=$(curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  "https://secretmanager.googleapis.com/v1/projects/${PROJECT_ID}/secrets/${SECRET_NAME}/versions/latest:access" \
  | grep -o '"data":"[^"]*"' | sed 's/"data":"//;s/"$//')
OPENROUTER_KEY=$(echo "${SECRET_B64}" | base64 -d)

# Create openclaw user and dirs
log "Creating openclaw user and config dir..."
if ! id -u "${OPENCLAW_USER}" &>/dev/null; then
  useradd -m -r -s /bin/bash -d "${OPENCLAW_HOME}" "${OPENCLAW_USER}"
fi
mkdir -p "${CONFIG_DIR}"
chown -R "${OPENCLAW_USER}:${OPENCLAW_USER}" "${OPENCLAW_HOME}"

# Write openclaw.json per OpenRouter docs (https://docs.openclaw.ai/providers/openrouter): env.OPENROUTER_API_KEY, agents.defaults.model.primary
export OPENROUTER_KEY CONFIG_FILE
node -e '
const key = process.env.OPENROUTER_KEY;
const config = {
  env: { OPENROUTER_API_KEY: key },
  agents: {
    defaults: {
      model: { primary: "openrouter/anthropic/claude-sonnet-4-5" }
    }
  }
};
require("fs").writeFileSync(process.env.CONFIG_FILE, JSON.stringify(config, null, 2));
' 
chown "${OPENCLAW_USER}:${OPENCLAW_USER}" "${CONFIG_FILE}"
chmod 600 "${CONFIG_FILE}"
unset OPENROUTER_KEY

# Install OpenClaw globally (https://docs.openclaw.ai/install)
log "Installing OpenClaw..."
npm install -g openclaw@latest

# Systemd unit for OpenClaw gateway
log "Configuring systemd and starting gateway..." (runs as openclaw user, port 18789; see docs.openclaw.ai/cli/daemon)
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
ExecStart=/usr/bin/npx openclaw gateway --port 18789
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw

log "Startup script finished. Gateway should be running on port 18789."
