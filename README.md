# fire

Run [OpenClaw](https://docs.openclaw.ai) — an open-source personal AI assistant — on a **GCP Compute Engine VM**, fully automated with Pulumi.

Two deployment modes:
- **Desktop VM** (`fire-desktop`) — Ubuntu desktop you remote into via **Chrome Remote Desktop**, with OpenClaw running inside it. Access from any device (Mac, iPhone, iPad, Android) using your Google account. All data persists on GCS.
- **Server VM** (`fire-vm`) — Headless VM, chat via **Slack** from anywhere with no SSH needed.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  fire-desktop (Ubuntu 22.04, Cinnamon desktop)          │
│                                                         │
│  Chrome Remote Desktop ◀── remotedesktop.google.com    │
│                                                         │
│  OpenClaw gateway (port 18789)                          │
│    ├── config + memory → GCS bucket (.openclaw/)        │
│    ├── skills          → ~/fire-skills/ (GitHub)        │
│    └── Slack           → Socket Mode (outbound only)    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  fire-vm (server, headless)                             │
│                                                         │
│  OpenClaw gateway (port 18789)                          │
│    └── Slack ──▶ Slack API ──▶ OpenRouter ──▶ Claude   │
└─────────────────────────────────────────────────────────┘

Both VMs read credentials from GCP Secret Manager.
OpenClaw skills are loaded from a public GitHub repo (fire-skills).
```

---

## Repo layout

```
src/
  infra/
    setup/                         ← run this first (one-time bootstrap)
      Pulumi.yaml                  Project definition
      Pulumi.dev.yaml              Stack config (gitignored)
      index.ts                     Enables APIs, creates SA, grants IAM roles
    storage/
      Pulumi.yaml                  GCS bucket Pulumi program definition
      Pulumi.dev.yaml              Stack config (gitignored)
      index.ts                     Pulumi: GCS bucket + versioning
    vm-desktop/
      Pulumi.yaml                  Desktop VM Pulumi program definition
      Pulumi.dev.yaml              Stack config (gitignored)
      index.ts                     Pulumi: VM, IAM bindings, firewall
      scripts/
        vmdesktop-startup.sh       Startup script: install, configure, start
    vm-server/
      Pulumi.yaml                  Server VM Pulumi program definition
      Pulumi.dev.yaml              Stack config (gitignored)
      index.ts                     Pulumi: VM, IAM bindings, firewall
      scripts/
        vmstartup.sh               Startup script: install, configure, start
  skills/                          Git submodule → fire-skills repo
docs/
  server-vm.md                     Setup guide for the headless server VM
```

---

## Prerequisites

### 1. Tools

Install on your local machine:

```bash
# macOS
brew install --cask google-cloud-sdk
brew install pulumi
brew install node

# Verify
gcloud version
pulumi version
node --version
```

### 2. GCP account and project

These are the **only two manual steps** in GCP — everything else is automated by the `setup` Pulumi program below.

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create an account
2. Create a new project (note your `PROJECT_ID`)
3. **Enable billing** on the project (required for Compute Engine — [instructions](https://cloud.google.com/billing/docs/how-to/modify-project))

Then authenticate your local machine:
```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

**Run the setup program** — this enables all required APIs, creates the provisioner service account, and grants it the roles it needs:

```bash
# Edit src/infra/setup/Pulumi.dev.yaml and set gcp:project: YOUR_PROJECT_ID
npm install
pulumi stack init dev --cwd src/infra/setup
pulumi up -y --cwd src/infra/setup
```

It enables these APIs: `compute`, `secretmanager`, `iam`, `iamcredentials`, `storage`, `cloudresourcemanager`, `iap`, `oslogin`.

It creates a service account `fire-provisioner@YOUR_PROJECT_ID.iam.gserviceaccount.com` with roles: `compute.admin`, `secretmanager.admin`, `storage.admin`, `iam.serviceAccountUser`, `browser`.

Copy the `serviceAccountEmail` output — you'll paste it into each program's `Pulumi.dev.yaml` as `vmServiceAccountEmail`.

### 3. OpenRouter account

OpenRouter is an API aggregator — one key routes to Claude, GPT-4, Gemini, and hundreds of other models.

1. Sign up at [openrouter.ai](https://openrouter.ai) (free)
2. Go to **Keys** → **Create Key** → copy the key (starts with `sk-or-v1-...`)
3. Add credits (pay-as-you-go; Claude Sonnet ~$0.003/message)

### 4. Slack workspace and app

**Create a workspace** (skip if you already have one):
1. Go to [slack.com](https://slack.com) → **Create a new workspace** (free plan works)

**Create the Slack app:**
1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**
2. Select your workspace
3. Paste this manifest:

```json
{
  "display_information": { "name": "OpenClaw" },
  "features": {
    "bot_user": { "display_name": "OpenClaw", "always_online": false },
    "app_home": { "messages_tab_enabled": true, "messages_tab_read_only_enabled": false }
  },
  "oauth_config": {
    "scopes": {
      "bot": [
        "chat:write","channels:history","channels:read","groups:history",
        "im:history","im:read","im:write","mpim:history","mpim:read","mpim:write",
        "users:read","app_mentions:read","assistant:write",
        "reactions:read","reactions:write","pins:read","pins:write",
        "emoji:read","commands","files:read","files:write"
      ]
    }
  },
  "settings": {
    "socket_mode_enabled": true,
    "event_subscriptions": {
      "bot_events": [
        "app_mention","message.channels","message.groups","message.im","message.mpim",
        "reaction_added","reaction_removed","member_joined_channel","member_left_channel",
        "channel_rename","pin_added","pin_removed"
      ]
    }
  }
}
```

4. Click **Next** → **Create**
5. **OAuth & Permissions** → **Install to Workspace** → **Allow** → copy the **Bot Token** (`xoxb-...`)
6. **Settings → Basic Information → App-Level Tokens** → **Generate Token and Scopes** → add scope `connections:write` → copy the **App Token** (`xapp-...`)
7. **Settings → Socket Mode** → enable it

**Find your Slack user ID** (to allow yourself to DM the bot):
- Click your profile picture → **Profile** → **⋮** → **Copy member ID** (starts with `U...`)
- For multiple users: `U111AAA,U222BBB,U333CCC` (comma-separated)

### 5. Skills repository

OpenClaw loads skills from a public GitHub repository. The default is [jbadhree/fire-skills](https://github.com/jbadhree/fire-skills).

To use your own:
1. Fork the repo or create a new one with the same structure
2. Update `skillsRepoUrl` in your `Pulumi.dev.yaml` (see below)

---

## Setup — Desktop VM (recommended)

The desktop VM gives you a full Ubuntu desktop accessible from any device via Chrome Remote Desktop, with OpenClaw running inside it.

### Step 1 — Create GCS bucket for persistent storage

The bucket stores all OpenClaw data (config, memory, pairing) and Chrome Remote Desktop auth so it survives VM destroy/recreate.

```bash
# Initialize and deploy the storage program (only once, ever)
cd src/infra/storage
pulumi stack init dev
pulumi up -y --cwd src/infra/storage
```

Or create the bucket manually:
```bash
gcloud storage buckets create gs://YOUR_BUCKET_NAME \
  --location=US --project=YOUR_PROJECT_ID
```

### Step 2 — Create a desktop user password secret

This password is used for `sudo` inside the desktop (not for CRD login — CRD uses your Google account).

```bash
echo -n "your-sudo-password" | gcloud secrets create desktop-user-password \
  --project=YOUR_PROJECT_ID --data-file=-
```

### Step 3 — Store all secrets in GCP Secret Manager

```bash
PROJECT=YOUR_PROJECT_ID

# OpenRouter API key
echo -n "sk-or-v1-YOUR-KEY" | gcloud secrets create openrouter-api-key \
  --project=${PROJECT} --data-file=-

# Slack bot token (xoxb-...)
echo -n "xoxb-YOUR-BOT-TOKEN" | gcloud secrets create slack-bot-token \
  --project=${PROJECT} --data-file=-

# Slack app token (xapp-...)
echo -n "xapp-YOUR-APP-TOKEN" | gcloud secrets create slack-app-token \
  --project=${PROJECT} --data-file=-

# Your Slack user ID(s) — comma-separated for multiple users
echo -n "U0YOURSLACKID" | gcloud secrets create slack-allowed-user-ids \
  --project=${PROJECT} --data-file=-

# Desktop user sudo password (already done in Step 2)
# echo -n "your-sudo-password" | gcloud secrets create desktop-user-password ...
```

**To add multiple Slack users:**
```bash
echo -n "U111AAA,U222BBB,U333CCC" | gcloud secrets versions add slack-allowed-user-ids \
  --project=${PROJECT} --data-file=-
```

### Step 4 — Configure Pulumi

```bash
cd src/infra/vm-desktop
npm install          # from repo root if not already done
pulumi stack init dev
```

Create `src/infra/vm-desktop/Pulumi.dev.yaml` with your values:

```yaml
config:
  gcp:project: YOUR_PROJECT_ID          # e.g. my-gcp-project
  gcp:zone: us-central1-a               # change to your preferred zone

  fire-desktop:machineType: e2-standard-4    # 4 vCPU, 16GB RAM
  fire-desktop:diskSizeGb: "50"              # GB — increase if you need more space
  fire-desktop:instanceName: fire-desktop    # VM name in GCP console
  fire-desktop:imageFamily: ubuntu-2204-lts  # Ubuntu 22.04 LTS (recommended)
  fire-desktop:imageProject: ubuntu-os-cloud
  fire-desktop:assignExternalIp: "true"      # needed for CRD and outbound internet
  fire-desktop:startupScriptPath: scripts/vmdesktop-startup.sh

  fire-desktop:vmServiceAccountEmail: fire-provisioner@YOUR_PROJECT_ID.iam.gserviceaccount.com

  fire-desktop:desktopUsername: fire         # Linux username inside the desktop
  fire-desktop:desktopUserPasswordSecretName: desktop-user-password  # secret name from Step 2

  fire-desktop:openrouterSecretName: openrouter-api-key    # secret name from Step 3
  fire-desktop:slackBotSecretName: slack-bot-token         # secret name from Step 3
  fire-desktop:slackAppSecretName: slack-app-token         # secret name from Step 3
  fire-desktop:slackAllowedUserIdsSecretName: slack-allowed-user-ids

  fire-desktop:skillsRepoUrl: https://github.com/jbadhree/fire-skills.git  # or your fork
  fire-desktop:nodeMajorVersion: "22"
  fire-desktop:openclawVersion: 2026.3.13

  fire-desktop:gcsBucketName: YOUR_BUCKET_NAME  # bucket created in Step 1
```

> `encryptionsalt` is added automatically by `pulumi stack init` — do not add it manually.

### Step 5 — Deploy

```bash
pulumi up -y --cwd src/infra/vm-desktop
```

Pulumi creates: the VM, IAM bindings on all secrets and the GCS bucket, and a firewall rule for SSH (IAP only).

**Monitor the startup script** (~15-20 minutes on first boot):
```bash
gcloud compute instances get-serial-port-output fire-desktop \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```

Wait until you see: `[desktop-startup] ... Startup script finished.`

### Step 6 — Set up Chrome Remote Desktop (one-time)

This authorization links the VM to your Google account. After it's done once, CRD auth is stored in GCS and survives destroy/recreate.

**1. Get the authorization command:**
- Open [remotedesktop.google.com/headless](https://remotedesktop.google.com/headless) in your browser (signed in to your Google account)
- Click **Begin** → **Authorize** → allow the permissions
- Copy the full command shown (starts with `DISPLAY= /opt/google/chrome-remote-desktop/start-host ...`)

**2. SSH into the VM:**
```bash
gcloud compute ssh fire-desktop \
  --zone=us-central1-a \
  --tunnel-through-iap \
  --project=YOUR_PROJECT_ID
```

**3. Run the authorization command as your desktop user:**
```bash
sudo -u fire DISPLAY= /opt/google/chrome-remote-desktop/start-host \
  --code="4/xxxx..." \
  --redirect-url="https://remotedesktop.google.com/_/oauthredirect" \
  --name=$(hostname)
```
Enter a **6-digit PIN** when prompted — you'll use this PIN every time you connect.

**4. Connect:**
- Open [remotedesktop.google.com](https://remotedesktop.google.com) on any device
- Click **Remote Access** → click `fire-desktop`
- Enter your 6-digit PIN

Works on **Mac, iPhone, iPad, Android** — no VPN, no extra apps.

### Step 7 — Access OpenClaw dashboard

Once connected to the desktop, open **Firefox** and go to:
```
http://localhost:18789
```

---

## Server VM (headless, Slack only)

For a lighter-weight option without a desktop — OpenClaw accessible only via Slack.

See **[docs/server-vm.md](docs/server-vm.md)** for full setup instructions.

---

## Day-to-day usage

### Stop the VM (pause billing)
```bash
gcloud compute instances stop fire-desktop --zone=us-central1-a --project=YOUR_PROJECT_ID
```
Compute billing pauses. Disk and GCS data are retained.

### Start the VM again
```bash
gcloud compute instances start fire-desktop --zone=us-central1-a --project=YOUR_PROJECT_ID
```
Everything comes back automatically (~2 min for subsequent boots). CRD reconnects without re-authorization.

### Update secrets (e.g. rotate API key)
```bash
echo -n "sk-or-v1-NEW-KEY" | gcloud secrets versions add openrouter-api-key \
  --project=YOUR_PROJECT_ID --data-file=-
```
Reboot the VM to apply: `gcloud compute instances reset fire-desktop --zone=us-central1-a`

### Update OpenClaw version
Change in `Pulumi.dev.yaml`:
```yaml
fire-desktop:openclawVersion: 2026.4.1
```
Then destroy and recreate: `pulumi destroy -y --cwd src/infra/vm-desktop && pulumi up -y --cwd src/infra/vm-desktop`

### Add a Slack channel
Ask OpenClaw in Slack or the dashboard: *"Add channel C1234ABCD to OpenClaw"* — the `add-slack-channel` skill handles the config update and safe restart.

---

## What persists on GCS

All important data is stored in the GCS bucket — survives VM stop/start AND destroy/recreate:

| Data | GCS path | What it is |
|------|----------|------------|
| OpenClaw config | `.openclaw/openclaw.json` | API keys, Slack tokens, channel policy |
| OpenClaw memory | `.openclaw/memory/` | Conversation history and context |
| Pairing data | `.openclaw/` | Device pairing tokens |
| CRD auth | `.crd-config/` | Chrome Remote Desktop registration — no re-auth after recreate |

**Only destroyed on `pulumi destroy` + manual bucket deletion.** Stop/start and destroy/recreate are both safe.

---

## Configuration reference — Desktop VM

| Key | Default | Description |
|-----|---------|-------------|
| `gcp:project` | — | GCP project ID (required) |
| `gcp:zone` | `us-central1-a` | VM zone |
| `machineType` | `e2-standard-4` | VM size |
| `diskSizeGb` | `50` | Boot disk size in GB |
| `instanceName` | `fire-desktop` | VM name |
| `imageFamily` | `ubuntu-2204-lts` | OS image family |
| `imageProject` | `ubuntu-os-cloud` | OS image project |
| `assignExternalIp` | `true` | Needed for CRD and internet access |
| `vmServiceAccountEmail` | default compute SA | SA the VM runs as |
| `desktopUsername` | `fire` | Linux user created on first boot |
| `desktopUserPasswordSecretName` | `desktop-user-password` | Secret for sudo password |
| `openrouterSecretName` | `openrouter-api-key` | Secret for OpenRouter key |
| `slackBotSecretName` | `slack-bot-token` | Secret for Slack bot token |
| `slackAppSecretName` | `slack-app-token` | Secret for Slack app token |
| `slackAllowedUserIdsSecretName` | `slack-allowed-user-ids` | Secret for allowed Slack user IDs |
| `skillsRepoUrl` | `https://github.com/jbadhree/fire-skills.git` | Skills GitHub repo |
| `nodeMajorVersion` | `22` | Node.js major version |
| `openclawVersion` | `2026.3.13` | Pinned OpenClaw version |
| `gcsBucketName` | — | GCS bucket name (required) |

---

## Troubleshooting

### Startup script failed — check logs
```bash
gcloud compute instances get-serial-port-output fire-desktop \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```

### SSH into the VM for debugging
```bash
gcloud compute ssh fire-desktop \
  --zone=us-central1-a \
  --tunnel-through-iap \
  --project=YOUR_PROJECT_ID
```

### Check OpenClaw service status
```bash
# From inside the VM or via SSH
systemctl status openclaw-desktop
journalctl -u openclaw-desktop -f
```

### `fire-desktop` doesn't appear on remotedesktop.google.com
The one-time CRD authorization hasn't been done yet on this VM. Follow Step 6 of the setup.

### Permission denied on GCS mount
The VM's service account doesn't have `roles/storage.objectAdmin` on the bucket. Run `pulumi up` to re-apply IAM bindings, then reboot the VM.

### Secret fetch failed
The VM can't read a secret. Check it exists and the VM's SA has access:
```bash
gcloud secrets list --project=YOUR_PROJECT_ID
gcloud secrets get-iam-policy openrouter-api-key --project=YOUR_PROJECT_ID
```
Then run `pulumi up` (re-applies IAM) and reboot.

### OpenClaw not responding in Slack
Wait ~2 min after boot. Then check:
```bash
# From inside the VM
systemctl status openclaw-desktop
curl http://localhost:18789/health
```

### 403 `iam.serviceAccounts.getAccessToken` denied (Pulumi deploy fails)
Run Pulumi as your own Google account instead:
```bash
gcloud auth application-default login
pulumi up -y --cwd src/infra/vm-desktop
```
