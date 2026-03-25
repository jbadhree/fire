# fire

Run [OpenClaw](https://docs.openclaw.ai) — an open-source personal AI assistant — on a **GCP Compute Engine VM**, fully automated with Pulumi.

Two deployment modes:
- **Desktop VM** (`fire-desktop`) — Ubuntu desktop accessible via **Chrome Remote Desktop** from any device (Mac, iPhone, iPad, Android). OpenClaw runs inside it. All data persists on GCS.
- **Server VM** (`fire-vm`) — Headless VM, chat via **Slack** from anywhere. See [docs/server-vm.md](docs/server-vm.md).

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

Both VMs read credentials from GCP Secret Manager.
OpenClaw skills are loaded from a public GitHub repo (fire-skills).
```

---

## Repo layout

```
src/
  infra/
    setup/          ← run this first (one-time bootstrap per project)
    storage/        ← GCS bucket for persistent data
    vm-desktop/     ← Ubuntu desktop VM with Chrome Remote Desktop
    vm-server/      ← Headless server VM (Slack only)
docs/
  server-vm.md      ← Setup guide for the server VM
```

---

## Prerequisites

### 1. Install tools (macOS)

```bash
brew install --cask google-cloud-sdk
brew install pulumi
brew install node
```

### 2. GCP — create project and enable billing

1. Go to [console.cloud.google.com](https://console.cloud.google.com) → create an account and a new project
2. Note your `PROJECT_ID`
3. **Enable billing** on the project ([instructions](https://cloud.google.com/billing/docs/how-to/modify-project)) — required for Compute Engine

### 3. OpenRouter account

1. Sign up at [openrouter.ai](https://openrouter.ai) (free)
2. Go to **Keys** → **Create Key** → copy the key (starts with `sk-or-v1-...`)
3. Add credits (pay-as-you-go; Claude Sonnet ~$0.003/message)

### 4. Slack workspace and app

**Create a workspace** (skip if you already have one):
- Go to [slack.com](https://slack.com) → **Create a new workspace** (free plan works)

**Create the Slack app:**
1. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest**
2. Select your workspace and paste this manifest:

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

3. Click **Next** → **Create**
4. **OAuth & Permissions** → **Install to Workspace** → **Allow** → copy the **Bot Token** (`xoxb-...`)
5. **Settings → Basic Information → App-Level Tokens** → **Generate Token and Scopes** → add scope `connections:write` → copy the **App Token** (`xapp-...`)
6. **Settings → Socket Mode** → enable it

**Find your Slack user ID:**
- Click your profile picture → **Profile** → **⋮** → **Copy member ID** (starts with `U...`)
- Multiple users: `U111AAA,U222BBB` (comma-separated)

---

## Setup — step by step

### Step 1 — Clone repo and install dependencies

```bash
git clone https://github.com/jbadhree/fire.git
cd fire
npm install
```

### Step 2 — Authenticate gcloud

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project YOUR_PROJECT_ID
```

### Step 3 — Bootstrap GCP (one-time per project)

This enables all required APIs, creates a provisioner service account, and grants it the IAM roles it needs.

Edit `src/infra/setup/Pulumi.dev.yaml` — set your project ID:
```yaml
config:
  gcp:project: YOUR_PROJECT_ID
  fire-setup:serviceAccountName: fire-provisioner
  fire-setup:serviceAccountDisplayName: Fire infrastructure provisioner
```

Then run:
```bash
pulumi stack init dev --cwd src/infra/setup
pulumi up -y --cwd src/infra/setup
```

> **Note:** If you see `error: stack 'dev' already exists` — you've run this before. Skip `stack init` and go straight to `pulumi up`.

From the output, copy the `serviceAccountEmail` value — you'll need it in later steps.

APIs enabled: `compute`, `secretmanager`, `iam`, `iamcredentials`, `storage`, `cloudresourcemanager`, `iap`, `oslogin`.

### Step 4 — Create GCS bucket for persistent storage

The bucket stores all OpenClaw data (config, memory, pairing) and Chrome Remote Desktop auth — everything survives VM stop/start and destroy/recreate.

Edit `src/infra/storage/Pulumi.dev.yaml`:
```yaml
config:
  gcp:project: YOUR_PROJECT_ID
  fire-storage:gcsBucketName: YOUR_UNIQUE_BUCKET_NAME   # globally unique, e.g. yourname-openclaw-data
  fire-storage:location: US
```

> Bucket names are globally unique across all GCP. If the name is taken you'll get an error — just pick a different name.

```bash
pulumi stack init dev --cwd src/infra/storage
pulumi up -y --cwd src/infra/storage
```

### Step 5 — Store secrets in GCP Secret Manager

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

# Desktop user sudo password (any password — used for sudo inside the VM, not for CRD login)
echo -n "your-sudo-password" | gcloud secrets create desktop-user-password \
  --project=${PROJECT} --data-file=-
```

### Step 6 — Configure the desktop VM

Edit `src/infra/vm-desktop/Pulumi.dev.yaml` — replace the three placeholder values:

```yaml
config:
  gcp:project: YOUR_PROJECT_ID           # ← your project ID
  gcp:zone: us-central1-a

  fire-desktop:machineType: e2-standard-4
  fire-desktop:diskSizeGb: "50"
  fire-desktop:instanceName: fire-desktop
  fire-desktop:imageFamily: ubuntu-2204-lts
  fire-desktop:imageProject: ubuntu-os-cloud
  fire-desktop:assignExternalIp: "true"
  fire-desktop:startupScriptPath: scripts/vmdesktop-startup.sh

  fire-desktop:vmServiceAccountEmail: fire-provisioner@YOUR_PROJECT_ID.iam.gserviceaccount.com  # ← from Step 3 output

  fire-desktop:desktopUsername: fire
  fire-desktop:desktopUserPasswordSecretName: desktop-user-password
  fire-desktop:openrouterSecretName: openrouter-api-key
  fire-desktop:slackBotSecretName: slack-bot-token
  fire-desktop:slackAppSecretName: slack-app-token
  fire-desktop:slackAllowedUserIdsSecretName: slack-allowed-user-ids

  fire-desktop:skillsRepoUrl: https://github.com/jbadhree/fire-skills.git
  fire-desktop:nodeMajorVersion: "22"
  fire-desktop:openclawVersion: 2026.3.13

  fire-desktop:gcsBucketName: YOUR_UNIQUE_BUCKET_NAME   # ← same bucket name as Step 4
```

> `encryptionsalt` is added automatically by `pulumi stack init` — do not add it manually. **Never delete it** from the file after it's been added.

> **Tip:** Set `PULUMI_CONFIG_PASSPHRASE` as an env var to avoid being prompted for it on every command:
> ```bash
> export PULUMI_CONFIG_PASSPHRASE="your-passphrase"
> ```

### Step 7 — Deploy the desktop VM

```bash
pulumi stack init dev --cwd src/infra/vm-desktop
pulumi up -y --cwd src/infra/vm-desktop
```

Pulumi creates the VM, IAM bindings on all secrets and the GCS bucket, and a firewall rule for SSH (IAP only).

**Monitor first boot** (~15-20 minutes):
```bash
gcloud compute instances get-serial-port-output fire-desktop \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```

Wait until you see: `[desktop-startup] ... Startup script finished.`

### Step 8 — Set up Chrome Remote Desktop (one-time)

This authorization links the VM to your Google account. Once done, it's stored in GCS and survives VM destroy/recreate — you won't need to do this again.

**1. Get the authorization command:**
- Open [remotedesktop.google.com/headless](https://remotedesktop.google.com/headless) in your browser (signed in to your Google account)
- Click **Begin** → **Authorize** → allow the permissions
- Copy the full `start-host` command shown on the page

**2. SSH into the VM:**
```bash
gcloud compute ssh fire-desktop \
  --zone=us-central1-a \
  --tunnel-through-iap \
  --project=YOUR_PROJECT_ID
```

**3. Run the command as your desktop user:**
```bash
sudo -u fire DISPLAY= /opt/google/chrome-remote-desktop/start-host \
  --code="4/xxxx..." \
  --redirect-url="https://remotedesktop.google.com/_/oauthredirect" \
  --name=$(hostname)
```
Enter a **6-digit PIN** when prompted — you'll use this every time you connect.

**4. Connect from any device:**
- Open [remotedesktop.google.com](https://remotedesktop.google.com) → **Remote Access** → click `fire-desktop`
- Enter your 6-digit PIN

Works on **Mac, iPhone, iPad, Android** — no VPN needed.

### Step 9 — Verify OpenClaw is running

After the startup script finishes, OpenClaw takes ~1-2 minutes to fully initialize. Check from inside the VM (via SSH or CRD terminal):

```bash
systemctl status openclaw-desktop
curl http://localhost:18789/health
```

Or from the CRD desktop session, open **Firefox** and go to `http://localhost:18789`.

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
OpenClaw comes back automatically in ~2 minutes. CRD reconnects without re-authorization.

> OpenClaw takes ~1-2 min after the VM starts before it's fully ready. If Slack doesn't respond immediately, wait a moment and try again.

### SSH into the VM
```bash
gcloud compute ssh fire-desktop \
  --zone=us-central1-a \
  --tunnel-through-iap \
  --project=YOUR_PROJECT_ID
```

### Check OpenClaw logs
```bash
# Live service logs
journalctl -u openclaw-desktop -f

# Startup script log
sudo cat /tmp/desktop-startup.log
```

### Update a secret (e.g. rotate API key)
```bash
echo -n "sk-or-v1-NEW-KEY" | gcloud secrets versions add openrouter-api-key \
  --project=YOUR_PROJECT_ID --data-file=-
```
Reboot to apply:
```bash
gcloud compute instances reset fire-desktop --zone=us-central1-a --project=YOUR_PROJECT_ID
```

### Update OpenClaw version
Change in `Pulumi.dev.yaml`:
```yaml
fire-desktop:openclawVersion: 2026.4.1
```
Then redeploy: `pulumi destroy -y --cwd src/infra/vm-desktop && pulumi up -y --cwd src/infra/vm-desktop`

---

## Teardown

Destroy in this order — VM first, then storage, then setup:

```bash
# 1. Delete the VM (safe — GCS data is unaffected)
pulumi destroy -y --cwd src/infra/vm-desktop

# 2. Delete the GCS bucket and ALL its data (OpenClaw config, memory, CRD auth)
pulumi destroy -y --cwd src/infra/storage

# 3. Remove service account and IAM roles (optional — harmless to leave)
pulumi destroy -y --cwd src/infra/setup
```

> The GCS bucket has `forceDestroy: true` — `pulumi destroy` will delete all objects in it. This is permanent. If you want to keep your OpenClaw data, download it first:
> ```bash
> gcloud storage cp -r gs://YOUR_BUCKET_NAME ./openclaw-backup
> ```

> `pulumi destroy` on setup removes the service account and IAM bindings but does **not** disable APIs (`disableOnDestroy: false`) — disabling APIs could break other things in the project.

---

## Working from a different machine

Pulumi state is stored in Pulumi Cloud (linked to your account) by default — not locally. So if you're using Pulumi Cloud, you can just clone the repo on the new machine, install tools, authenticate gcloud, and run `pulumi up` or `pulumi destroy` directly.

If you're using **local state** (passphrase-based), you need to transfer the state:

```bash
# On current machine — export all three stacks
pulumi stack export --cwd src/infra/setup   > setup-state.json
pulumi stack export --cwd src/infra/storage > storage-state.json
pulumi stack export --cwd src/infra/vm-desktop > vm-desktop-state.json
```

Copy the JSON files and the `Pulumi.dev.yaml` files to the new machine, then:

```bash
export PULUMI_CONFIG_PASSPHRASE="your-passphrase"

pulumi stack import --cwd src/infra/setup   < setup-state.json
pulumi stack import --cwd src/infra/storage < storage-state.json
pulumi stack import --cwd src/infra/vm-desktop < vm-desktop-state.json
```

---

## Moving to a new GCP project

If you have existing Pulumi state pointing at an old project and want to redeploy in a new one:

1. Export state (backup):
```bash
pulumi stack export --cwd src/infra/vm-desktop > vm-desktop-old-state.json
```

2. Update `Pulumi.dev.yaml` files with the new project ID and service account email

3. Refresh to clear stale state (removes old project's resources from state):
```bash
export PULUMI_CONFIG_PASSPHRASE="your-passphrase"
pulumi refresh -y --cwd src/infra/vm-desktop
```

4. Deploy fresh:
```bash
pulumi up -y --cwd src/infra/vm-desktop
```

> **Important:** Never delete `encryptionsalt` from `Pulumi.dev.yaml` when editing it — Pulumi needs it to decrypt the stack's secrets. If you accidentally lose it, import the exported state JSON to restore it.

---

## What persists on GCS

All important data lives in the GCS bucket — survives stop/start AND destroy/recreate:

| Data | GCS path | What it is |
|------|----------|------------|
| OpenClaw config | `.openclaw/openclaw.json` | API keys, Slack tokens, channel policy |
| OpenClaw memory | `.openclaw/memory/` | Conversation history and context |
| Pairing data | `.openclaw/` | Device pairing tokens |
| CRD auth | `.crd-config/` | Chrome Remote Desktop registration |

**Only permanently deleted by `pulumi destroy --cwd src/infra/storage`.**

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

### `error: stack 'dev' already exists` on `pulumi stack init`
The stack was already initialized. Skip `pulumi stack init` and run `pulumi up` directly.

### Pulumi keeps prompting for passphrase
Set it as an environment variable:
```bash
export PULUMI_CONFIG_PASSPHRASE="your-passphrase"
```

### Startup script failed
```bash
gcloud compute instances get-serial-port-output fire-desktop \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```
Look for `FAILED at line` in the output.

### OpenClaw not responding (health check fails)
OpenClaw takes ~1-2 minutes after the VM boots to fully initialize. Wait, then:
```bash
systemctl status openclaw-desktop
journalctl -u openclaw-desktop --no-pager | tail -30
curl http://localhost:18789/health
```

### `fire-desktop` doesn't appear on remotedesktop.google.com
The one-time CRD authorization hasn't been done yet. Follow Step 8.

### Permission denied on GCS mount
```bash
pulumi up -y --cwd src/infra/vm-desktop   # re-applies IAM bindings
gcloud compute instances reset fire-desktop --zone=us-central1-a --project=YOUR_PROJECT_ID
```

### Secret fetch failed
```bash
gcloud secrets list --project=YOUR_PROJECT_ID
gcloud secrets get-iam-policy openrouter-api-key --project=YOUR_PROJECT_ID
```
Then `pulumi up` to re-apply IAM, then reboot.

### 403 `iam.serviceAccounts.getAccessToken` denied (Pulumi deploy fails)
```bash
gcloud auth application-default login
pulumi up -y --cwd src/infra/vm-desktop
```

### Moving to a new GCP project causes errors on `pulumi up`
Old state has resources from the previous project. Export state, refresh, then up:
```bash
pulumi stack export --cwd src/infra/vm-desktop > backup.json
pulumi refresh -y --cwd src/infra/vm-desktop
pulumi up -y --cwd src/infra/vm-desktop
```
