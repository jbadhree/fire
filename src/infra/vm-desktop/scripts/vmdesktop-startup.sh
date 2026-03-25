#!/bin/bash
# Startup script: runs on EVERY boot (GCP default).
# Placeholders replaced by Pulumi: __PROJECT_ID__, __DESKTOP_USER__,
#   __DESKTOP_USER_PASSWORD_SECRET_NAME__, __GCS_BUCKET_NAME__,
#   __OPENROUTER_SECRET_NAME__, __SLACK_BOT_SECRET_NAME__,
#   __SLACK_APP_SECRET_NAME__, __SLACK_ALLOWED_USER_IDS_SECRET_NAME__,
#   __SKILLS_REPO_URL__, __NODE_MAJOR_VERSION__, __OPENCLAW_VERSION__
# Debug: cat /tmp/desktop-startup.log  OR  gcloud compute instances get-serial-port-output

set -e

STARTUP_LOG="/tmp/desktop-startup.log"
exec > >(tee -a "$STARTUP_LOG") 2>&1

log() { echo "[desktop-startup] $(date -Iseconds) $*"; }
trap 'log "FAILED at line $LINENO"; exit 1' ERR

# ── Pulumi-injected values (all placeholders live here) ──────────────────────
PROJECT_ID="__PROJECT_ID__"
DESKTOP_USER="__DESKTOP_USER__"
DESKTOP_USER_PASSWORD_SECRET_NAME="__DESKTOP_USER_PASSWORD_SECRET_NAME__"
GCS_BUCKET_NAME="__GCS_BUCKET_NAME__"
OPENROUTER_SECRET_NAME="__OPENROUTER_SECRET_NAME__"
SLACK_BOT_SECRET_NAME="__SLACK_BOT_SECRET_NAME__"
SLACK_APP_SECRET_NAME="__SLACK_APP_SECRET_NAME__"
SLACK_ALLOWED_USER_IDS_SECRET_NAME="__SLACK_ALLOWED_USER_IDS_SECRET_NAME__"
SKILLS_REPO_URL="__SKILLS_REPO_URL__"
NODE_MAJOR="__NODE_MAJOR_VERSION__"
OPENCLAW_VERSION="__OPENCLAW_VERSION__"

# ── Derived variables ─────────────────────────────────────────────────────────
DESKTOP_HOME="/home/${DESKTOP_USER}"
GCS_MOUNT_DIR="${DESKTOP_HOME}/gcs"
# All OpenClaw data lives here on GCS — persists across VM recreates.
# The startup script symlinks ~/.openclaw → this dir so OpenClaw writes here too.
OPENCLAW_CONFIG_DIR="${GCS_MOUNT_DIR}/.openclaw"
OPENCLAW_CONFIG_FILE="${OPENCLAW_CONFIG_DIR}/openclaw.json"
# fire-skills on local disk — git operations are faster off GCS.
FIRE_SKILLS_DIR="${DESKTOP_HOME}/fire-skills"
INITIALIZED_MARKER="/var/lib/.desktop-initialized"

export DEBIAN_FRONTEND=noninteractive

log "Starting desktop VM startup script (boot)."

# ── Install once ─────────────────────────────────────────────────────────────
if [ ! -f "${INITIALIZED_MARKER}" ]; then
  log "First boot: installing Cinnamon, CRD, Node.js, and OpenClaw (~15-20 min)..."

  apt-get update -qq

  # ── Desktop environment (install BEFORE CRD) ──────────────────────────────
  # Cinnamon: modern-looking desktop, CRD-compatible in 2D mode (no GPU needed).
  # Must be installed before CRD so the session binary exists during CRD postinstall.
  # dbus-x11: required for the Cinnamon session bus under CRD.
  log "Installing Cinnamon desktop..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cinnamon-core \
    desktop-base \
    dbus-x11

  # Disable any display managers — CRD owns the display.
  systemctl disable lightdm.service 2>/dev/null || true
  systemctl disable gdm3.service 2>/dev/null || true

  # ── Chrome Remote Desktop ──────────────────────────────────────────────────
  log "Installing Chrome Remote Desktop..."
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/chrome-remote-desktop.gpg
  echo "deb [arch=amd64] https://dl.google.com/linux/chrome-remote-desktop/deb stable main" \
    > /etc/apt/sources.list.d/chrome-remote-desktop.list
  apt-get update -qq

  # ── Patch adduser.conf (Ubuntu 22.04 bug workaround) ─────────────────────
  # Problem: CRD's postinstall script creates a system user named '_crd_network'
  # to sandbox its network process. Ubuntu 22.04's default NAME_REGEX in
  # /etc/adduser.conf is "^[a-z][-a-z0-9]*$?" which only allows names starting
  # with a-z. The leading underscore in '_crd_network' fails this check and
  # adduser rejects it, causing the entire CRD install to fail with:
  #   "adduser: Please enter a username matching the regular expression..."
  # Fix: patch NAME_REGEX to also allow names starting with '_' before installing CRD.
  # This only needs to run once — after '_crd_network' is created, the regex
  # doesn't matter anymore.
  python3 - << 'PYEOF'
import re, sys
path = "/etc/adduser.conf"
with open(path) as f:
    content = f.read()
content = re.sub(r"^NAME_REGEX=.*", 'NAME_REGEX="^[a-z_][a-z0-9_-]*\\$?"', content, flags=re.MULTILINE)
if "NAME_REGEX_SYSTEM=" not in content:
    content += '\nNAME_REGEX_SYSTEM="^[a-z_][a-z0-9_-]*\\$?"\n'
else:
    content = re.sub(r"^NAME_REGEX_SYSTEM=.*", 'NAME_REGEX_SYSTEM="^[a-z_][a-z0-9_-]*\\$?"', content, flags=re.MULTILINE)
with open(path, "w") as f:
    f.write(content)
print("adduser.conf patched OK")
PYEOF

  DEBIAN_FRONTEND=noninteractive apt-get install -y chrome-remote-desktop

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

  # ── Create desktop user ────────────────────────────────────────────────────
  if ! id -u "${DESKTOP_USER}" &>/dev/null; then
    log "Creating desktop user '${DESKTOP_USER}'..."
    useradd -m -s /bin/bash -G sudo "${DESKTOP_USER}"
  fi
  getent group fuse || groupadd -r fuse
  usermod -aG fuse "${DESKTOP_USER}"
  usermod -aG chrome-remote-desktop "${DESKTOP_USER}" 2>/dev/null || true

  # ── OpenClaw sudoers (restart without password) ───────────────────────────
  cat > /usr/local/bin/restart-openclaw.sh << 'EOF'
#!/bin/bash
systemctl restart openclaw-desktop
EOF
  chmod +x /usr/local/bin/restart-openclaw.sh
  echo "${DESKTOP_USER} ALL=(root) NOPASSWD: /usr/local/bin/restart-openclaw.sh" \
    > /etc/sudoers.d/openclaw-desktop-restart
  chmod 0440 /etc/sudoers.d/openclaw-desktop-restart

  # ── OpenClaw systemd unit ─────────────────────────────────────────────────
  # Why systemd instead of just running in the background:
  #   - Restart=on-failure: if OpenClaw crashes, systemd revives it automatically.
  #   - Clean shutdown: systemd sends SIGTERM on VM stop so in-flight GCS writes flush.
  #   - Observability: `systemctl status` and `journalctl -u openclaw-desktop` work.
  #
  # Why NOT enabled (no systemctl enable):
  #   - On boot, systemd would start it before this startup script runs.
  #   - At that point GCS isn't mounted yet and the config file doesn't exist.
  #   - Instead, the startup script starts it manually after GCS is ready.
  #   - Restart=on-failure still kicks in if it crashes AFTER the initial start.
  #
  # Unquoted heredoc delimiter so ${DESKTOP_USER} and ${DESKTOP_HOME} are expanded.
  cat > /etc/systemd/system/openclaw-desktop.service << SYSTEMD
[Unit]
Description=OpenClaw Gateway (Desktop)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${DESKTOP_USER}
Group=${DESKTOP_USER}
Environment=HOME=${DESKTOP_HOME}
# ~/.openclaw is symlinked to GCS by the startup script — all data persists.
Environment=OPENCLAW_CONFIG_PATH=${DESKTOP_HOME}/.openclaw/openclaw.json
Environment=NODE_OPTIONS=--max-old-space-size=2048
ExecStart=/usr/bin/npx openclaw gateway --port 18789 --allow-unconfigured
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD
  systemctl daemon-reload

  # ── Useful desktop apps ───────────────────────────────────────────────────
  log "Installing desktop utilities..."
  apt-get install -y -qq \
    firefox \
    gedit \
    gnome-terminal \
    curl \
    git \
    wget \
    unzip

  # ── Clone skills registry ─────────────────────────────────────────────────
  log "Cloning skills registry from ${SKILLS_REPO_URL}..."
  sudo -u "${DESKTOP_USER}" git clone \
    "${SKILLS_REPO_URL}" \
    "${FIRE_SKILLS_DIR}"
  log "Skills registry cloned."

  touch "${INITIALIZED_MARKER}"
  log "First-boot install complete."
else
  log "Already initialized — skipping install."
fi

# ── Set Cinnamon session based on GPU availability (runs on every boot) ───────
# Runs every boot so upgrading to a GPU VM type is picked up automatically.
# Checks for NVIDIA/AMD discrete GPU via lspci — ignores the virtual QEMU VGA
# that all GCE VMs have (that's software, not a real GPU).
if lspci 2>/dev/null | grep -qiE '(NVIDIA|AMD|ATI).*(VGA|3D|Display)|(VGA|3D|Display).*(NVIDIA|AMD|ATI)'; then
  CRD_SESSION="cinnamon-session"
  log "GPU detected — using Cinnamon with 3D compositing."
else
  CRD_SESSION="cinnamon-session-cinnamon2d"
  log "No GPU detected — using Cinnamon 2D mode (software rendering)."
fi
bash -c "echo \"exec /etc/X11/Xsession /usr/bin/${CRD_SESSION}\" > /etc/chrome-remote-desktop-session"

# ── Pull latest fire-skills (runs on every boot) ─────────────────────────────
log "Pulling latest fire-skills..."
if sudo -u "${DESKTOP_USER}" git -C "${FIRE_SKILLS_DIR}" pull --ff-only 2>/dev/null; then
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
    exit 1
  fi
  echo "${value}"
}

log "Fetching desktop user password..."
DESKTOP_USER_PASSWORD=$(fetch_secret "${DESKTOP_USER_PASSWORD_SECRET_NAME}" "desktop-user-password")

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
    SLACK_ALLOWED_USER_IDS=$(fetch_secret "${SLACK_ALLOWED_USER_IDS_SECRET_NAME}" "slack-allowed-user-ids")
  fi
fi

# ── Set desktop user password ─────────────────────────────────────────────────
log "Setting password for '${DESKTOP_USER}'..."
echo "${DESKTOP_USER}:${DESKTOP_USER_PASSWORD}" | chpasswd
unset DESKTOP_USER_PASSWORD

# ── Mount GCS bucket ──────────────────────────────────────────────────────────
log "Mounting GCS bucket ${GCS_BUCKET_NAME} at ${GCS_MOUNT_DIR}..."
mkdir -p "${GCS_MOUNT_DIR}"
chown "${DESKTOP_USER}:${DESKTOP_USER}" "${GCS_MOUNT_DIR}"

if ! mountpoint -q "${GCS_MOUNT_DIR}"; then
  DESKTOP_UID=$(id -u "${DESKTOP_USER}")
  DESKTOP_GID=$(id -g "${DESKTOP_USER}")
  # Run as root so -o allow_other is permitted without user_allow_other restriction.
  # Files appear owned by the desktop user via --uid/--gid.
  # gcsfuse 3.x removed --allow-other; the FUSE equivalent is -o allow_other.
  gcsfuse --implicit-dirs \
    --uid="${DESKTOP_UID}" --gid="${DESKTOP_GID}" \
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
sudo -u "${DESKTOP_USER}" mkdir -p "${OPENCLAW_CONFIG_DIR}/logs"

OPENCLAW_LOCAL_DIR="${DESKTOP_HOME}/.openclaw"
if [ -d "${OPENCLAW_LOCAL_DIR}" ] && [ ! -L "${OPENCLAW_LOCAL_DIR}" ]; then
  log "Migrating existing ~/.openclaw to GCS..."
  cp -r "${OPENCLAW_LOCAL_DIR}/." "${OPENCLAW_CONFIG_DIR}/" 2>/dev/null || true
  rm -rf "${OPENCLAW_LOCAL_DIR}"
fi
if [ ! -L "${OPENCLAW_LOCAL_DIR}" ]; then
  sudo -u "${DESKTOP_USER}" ln -sfn "${OPENCLAW_CONFIG_DIR}" "${OPENCLAW_LOCAL_DIR}"
  log "~/.openclaw symlinked to GCS."
fi

# ── Write OpenClaw config (to GCS — persists across VM recreates) ────────────
log "Updating OpenClaw config..."

export OPENROUTER_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USER_IDS OPENCLAW_CONFIG_FILE FIRE_SKILLS_DIR
sudo -E -u "${DESKTOP_USER}" python3 - << 'PYEOF'
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

# File is already owned by fire (Python ran as fire). Just tighten permissions.
sudo -u "${DESKTOP_USER}" chmod 600 "${OPENCLAW_CONFIG_FILE}"
unset OPENROUTER_KEY SLACK_BOT_TOKEN SLACK_APP_TOKEN SLACK_ALLOWED_USER_IDS

# ── Start OpenClaw ────────────────────────────────────────────────────────────
log "Starting OpenClaw gateway..."
systemctl restart openclaw-desktop
OPENCLAW_STATUS=$(systemctl is-active openclaw-desktop 2>/dev/null || echo "failed")
log "OpenClaw status: ${OPENCLAW_STATUS}"

# ── Persist CRD auth config to GCS ───────────────────────────────────────────
# CRD stores its host registration in ~/.config/chrome-remote-desktop/.
# By symlinking that dir to GCS, auth survives destroy/recreate of the VM.
CRD_GCS_DIR="${GCS_MOUNT_DIR}/.crd-config"
CRD_LOCAL_DIR="${DESKTOP_HOME}/.config/chrome-remote-desktop"

sudo -u "${DESKTOP_USER}" mkdir -p "${CRD_GCS_DIR}"
sudo -u "${DESKTOP_USER}" mkdir -p "${DESKTOP_HOME}/.config"

# If a real local directory exists (first boot, or pre-existing auth), migrate it to GCS.
if [ -d "${CRD_LOCAL_DIR}" ] && [ ! -L "${CRD_LOCAL_DIR}" ]; then
  log "Migrating existing CRD config to GCS..."
  cp -r "${CRD_LOCAL_DIR}/." "${CRD_GCS_DIR}/" 2>/dev/null || true
  rm -rf "${CRD_LOCAL_DIR}"
fi

# Symlink: local CRD config dir → GCS dir.
# After a destroy/recreate the GCS dir already has auth files; CRD starts without re-auth.
if [ ! -L "${CRD_LOCAL_DIR}" ]; then
  sudo -u "${DESKTOP_USER}" ln -sfn "${CRD_GCS_DIR}" "${CRD_LOCAL_DIR}"
  log "CRD config symlinked to GCS at ${CRD_GCS_DIR}."
else
  log "CRD config already symlinked to GCS."
fi

# ── Start Chrome Remote Desktop ───────────────────────────────────────────────
log "Starting Chrome Remote Desktop..."
systemctl restart "chrome-remote-desktop@${DESKTOP_USER}" 2>/dev/null || \
  log "CRD not yet authorized — complete one-time setup (see instructions below)."

CRD_ACTIVE=$(systemctl is-active "chrome-remote-desktop@${DESKTOP_USER}" 2>/dev/null || echo "inactive")

log "Startup script finished."
log "  Desktop user:    ${DESKTOP_USER}"
log "  GCS mount:       ${GCS_MOUNT_DIR}  (bucket: ${GCS_BUCKET_NAME})"
log "  OpenClaw config: ${OPENCLAW_CONFIG_FILE}"
log "  CRD auth:        ${CRD_GCS_DIR}  (persisted on GCS)"
log "  OpenClaw status: ${OPENCLAW_STATUS}"
log "  OpenClaw port:   18789"
log "  CRD status:      ${CRD_ACTIVE}"
log ""
if [ "${CRD_ACTIVE}" != "active" ]; then
  log "  ── ONE-TIME CRD SETUP REQUIRED ──────────────────────────────────────"
  log "  1. Open https://remotedesktop.google.com/headless"
  log "  2. Click Begin → Authorize → copy the command"
  log "  3. SSH in: gcloud compute ssh ${HOSTNAME} --tunnel-through-iap"
  log "  4. Run: sudo -u ${DESKTOP_USER} <paste command>"
  log "  ─────────────────────────────────────────────────────────────────────"
else
  log "  Connect: remotedesktop.google.com (any device)"
  log "  OpenClaw dashboard: http://localhost:18789 (open in desktop Firefox)"
fi
