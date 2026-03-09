# fire

Run [OpenClaw](https://docs.openclaw.ai) — an open-source personal AI assistant — on a **GCP Compute Engine VM**, fully automated with Pulumi. Chat via **Slack** from anywhere with no SSH needed day-to-day.

---

## What this repo does

- Provisions a Debian VM on Google Cloud using **Pulumi** (TypeScript)
- A startup script runs on every boot with two phases:
  - **First boot only (~5 min):** installs Node.js 22 and OpenClaw, creates the system user, and registers the systemd service
  - **Every boot (~10 sec):** fetches your **OpenRouter API key** and **Slack tokens** from GCP Secret Manager, merges them into the config, and (re)starts the gateway
- You chat with OpenClaw by **DMing your Slack bot** — no SSH tunnel needed
- **Stop/start the VM** from GCP Console anytime; everything comes back up automatically in ~30 seconds

---

## How it works

```
You (Slack) ──DM──▶ Slack API ──Socket Mode──▶ GCP VM (OpenClaw gateway)
                                                      │
                                               OpenRouter API
                                               (routes to Claude, GPT, etc.)
```

- **OpenClaw** is the AI assistant runtime. It manages conversations, memory, channels, and agents.
- **OpenRouter** is the model provider. It gives you access to Claude, GPT-4, Gemini, and hundreds of other models through one API key. You pay per token with no subscription.
- **Slack** is the chat interface. OpenClaw connects to Slack via Socket Mode (outbound from the VM — no inbound ports exposed to the internet).
- **GCP Secret Manager** stores all credentials (OpenRouter key, Slack tokens). Nothing sensitive lives in code or config files.

---

## Repo layout

| Path | Purpose |
|------|---------|
| `src/infra/vms/index.ts` | Pulumi stack: VM, firewall, Secret Manager IAM |
| `src/infra/vms/scripts/vmstartup.sh` | Startup script: install, configure, start OpenClaw |
| `Pulumi.dev.yaml` | Stack config (gitignored — never committed) |

---

## Prerequisites

### 1. OpenRouter account (free to sign up)

OpenRouter is an API aggregator — you get one key that routes to any AI model.

1. Sign up at [openrouter.ai](https://openrouter.ai) (free)
2. Go to **Keys** → **Create Key**
3. Copy the key (starts with `sk-or-v1-...`)
4. Add credits (pay-as-you-go; Claude Sonnet costs ~$0.003/message)

### 2. Slack workspace (free plan works)

You need a Slack workspace to create a bot. The free plan is sufficient.

**If you don't have a workspace:**
1. Go to [slack.com](https://slack.com) → **Create a new workspace** (free)
2. Follow the prompts — takes 2 minutes

**Create a Slack app:**
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
5. Go to **OAuth & Permissions** → **Install to Workspace** → **Allow** → copy the **Bot Token** (`xoxb-...`)
6. Go to **Settings → Basic Information → App-Level Tokens** → **Generate Token and Scopes** → add scope `connections:write` → copy the **App Token** (`xapp-...`)
7. Go to **Settings → Socket Mode** → enable it
8. Find your Slack user ID: click your profile picture → **Profile** → **⋮** → **Copy member ID** (starts with `U...`)

### 3. GCP account and project

1. Go to [console.cloud.google.com](https://console.cloud.google.com) — create an account and a project if you don't have one
2. Enable billing on the project (required for Compute Engine)
3. Install the gcloud CLI and Pulumi (macOS):
   ```bash
   brew install --cask google-cloud-sdk
   brew install pulumi
   ```
4. Authenticate and point gcloud at your project:
   ```bash
   gcloud auth application-default login
   gcloud config set account YOUR_EMAIL
   gcloud config set project YOUR_PROJECT_ID
   ```
5. Enable the required APIs:
   ```bash
   gcloud services enable compute.googleapis.com secretmanager.googleapis.com iam.googleapis.com
   ```
6. Create a service account that Pulumi will use to provision resources:
   ```bash
   gcloud iam service-accounts create YOUR_SA_NAME \
     --display-name="Pulumi provisioner" \
     --project=YOUR_PROJECT_ID
   ```
   This gives you `YOUR_SA_NAME@YOUR_PROJECT_ID.iam.gserviceaccount.com` — use that as `YOUR_SA_EMAIL` everywhere below.
7. Grant the service account the roles it needs:
   ```bash
   # Create and manage VMs and firewall rules
   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="serviceAccount:YOUR_SA_EMAIL" \
     --role="roles/compute.admin"

   # Create and manage secrets
   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="serviceAccount:YOUR_SA_EMAIL" \
     --role="roles/secretmanager.admin"

   # Attach a service account to the VM when creating it
   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
     --member="serviceAccount:YOUR_SA_EMAIL" \
     --role="roles/iam.serviceAccountUser"
   ```
8. Tell gcloud to use that service account for Pulumi commands:
   ```bash
   gcloud auth application-default login \
     --impersonate-service-account=YOUR_SA_EMAIL
   ```

---

## Setup

### Step 1 — Store secrets in GCP Secret Manager

```bash
# OpenRouter API key
echo -n "sk-or-v1-YOUR-KEY" | gcloud secrets create openrouter-api-key \
  --project=YOUR_PROJECT_ID --data-file=-

# Slack bot token
echo -n "xoxb-YOUR-BOT-TOKEN" | gcloud secrets create slack-bot-token \
  --project=YOUR_PROJECT_ID --data-file=-

# Slack app token
echo -n "xapp-YOUR-APP-TOKEN" | gcloud secrets create slack-app-token \
  --project=YOUR_PROJECT_ID --data-file=-

# Your Slack user ID (allows your DMs without any manual pairing)
echo -n "U0YOURSLACKID" | gcloud secrets create slack-allowed-user-ids \
  --project=YOUR_PROJECT_ID --data-file=-
```

### Step 2 — Configure Pulumi

```bash
# Install dependencies
npm install

# Create the dev stack (only needed once)
pulumi stack init dev
```

Then edit `Pulumi.dev.yaml` with your values (this file is gitignored — never committed):

```yaml
config:
  gcp:project: YOUR_PROJECT_ID        # your GCP project ID
  gcp:zone: us-central1-a             # change if you want a different zone
  fire-infra:machineType: e2-medium   # change if you want a different machine size
  fire-infra:instanceName: fire-vm    # change if you want a different VM name
  fire-infra:startupScriptPath: src/infra/vms/scripts/vmstartup.sh
  fire-infra:vmServiceAccountEmail: YOUR_SA_EMAIL  # the SA you created in prerequisite step 6
  fire-infra:slackBotSecretName: slack-bot-token          # placeholder — matches the secret name you created in Step 1; only change if you used a different name
  fire-infra:slackAppSecretName: slack-app-token          # placeholder — same as above
  fire-infra:slackAllowedUserIdsSecretName: slack-allowed-user-ids  # placeholder — same as above
```

> The three `slack*SecretName` values are just the **names** of the secrets in GCP Secret Manager, not the tokens themselves. If you used the exact `gcloud secrets create` commands in Step 1, you don't need to change these.

> `encryptionsalt` is added automatically by Pulumi the first time you run `pulumi stack init` — don't add it manually.

### Step 3 — Deploy

```bash
pulumi up
```

Pulumi creates the VM and grants it access to all secrets. First boot takes ~5 minutes (installs Node.js and OpenClaw). You can watch progress:

```bash
gcloud compute instances get-serial-port-output $(pulumi stack output vmName) \
  --zone=$(pulumi stack output vmZone) --project=YOUR_PROJECT_ID 2>&1 | tail -20
```

Wait until you see: `Startup script finished. Gateway running on port 18789.`

### Step 4 — DM your bot in Slack

Open Slack, find your bot (search by name), and send it a DM. It responds immediately — no SSH, no pairing, nothing else to do.

---

## Day-to-day usage

### Chat via Slack
Just DM your bot. The VM and Slack connection are always on.

### Stop the VM (pause billing)
```bash
gcloud compute instances stop $(pulumi stack output vmName) --zone=$(pulumi stack output vmZone) --project=YOUR_PROJECT_ID
```
Compute billing pauses. Disk is retained (~$0.04/GB/month).

### Start the VM again
```bash
gcloud compute instances start $(pulumi stack output vmName) --zone=$(pulumi stack output vmZone) --project=YOUR_PROJECT_ID
```
OpenClaw and Slack come back up automatically in ~30 seconds.

### Web dashboard (optional)
If you want the browser UI at `http://localhost:18789`:

**Step 1 — Get the dashboard URL with a valid token** (SSH into the VM):
```bash
gcloud compute ssh $(pulumi stack output vmName) --zone=$(pulumi stack output vmZone) --project=YOUR_PROJECT_ID \
  --tunnel-through-iap --command='sudo -u openclaw HOME=/var/lib/openclaw npx openclaw dashboard --no-open'
```
This prints a URL like `http://localhost:18789/#token=...` — copy the full URL including the `#token=...` part.

**Step 2 — Open a port-forwarding session:**
```bash
gcloud compute ssh $(pulumi stack output vmName) --zone=$(pulumi stack output vmZone) --project=YOUR_PROJECT_ID \
  --tunnel-through-iap -- -L 18789:127.0.0.1:18789
```
Keep this session open.

**Step 3 — Open the URL** you copied in Step 1 in your browser. The token in the URL authenticates you — opening `http://localhost:18789` without it will fail.

### Destroy and recreate
```bash
pulumi destroy && pulumi up
```
Everything rebuilds from scratch automatically. No manual steps needed after deploy.

---

## Configuration reference

All config is set via `pulumi config set` or in `Pulumi.dev.yaml` (gitignored).

| Key | Default | Description |
|-----|---------|-------------|
| `gcp:project` | gcloud default | GCP project ID |
| `gcp:zone` | `us-central1-a` | VM zone |
| `machineType` | `e2-medium` | VM size (4 GB RAM recommended minimum) |
| `instanceName` | `fire-vm` | VM name |
| `imageFamily` | `debian-12` | Boot disk OS |
| `startupScriptPath` | — | Path to startup script (required) |
| `vmServiceAccountEmail` | default compute SA | SA the VM runs as |
| `openrouterSecretName` | `openrouter-api-key` | Secret Manager secret name for OpenRouter key |
| `slackBotSecretName` | — | Secret name for Slack bot token (`xoxb-...`) |
| `slackAppSecretName` | — | Secret name for Slack app token (`xapp-...`) |
| `slackAllowedUserIdsSecretName` | — | Secret name for comma-separated Slack user IDs |

---

## Troubleshooting

### SSH times out / "connection timed out during banner exchange"

The VM is likely overloaded. Check what's happening without SSH:
```bash
gcloud compute instances get-serial-port-output $(pulumi stack output vmName) \
  --zone=$(pulumi stack output vmZone) --project=YOUR_PROJECT_ID 2>&1 | tail -30
```
If out of memory, use a larger machine type: `pulumi config set machineType e2-medium`, then `pulumi destroy && pulumi up`.

### OpenRouter secret empty or failed to fetch

The VM can't read the secret. Check it exists and the VM's service account has access:
```bash
gcloud secrets list --project=YOUR_PROJECT_ID
gcloud secrets get-iam-policy openrouter-api-key --project=YOUR_PROJECT_ID
```
If the binding is missing, `pulumi up` will fix it (Pulumi manages the IAM bindings). Then recreate: `pulumi destroy && pulumi up`.

### OpenClaw not responding in Slack after startup

Wait ~1 minute after the VM starts — the gateway takes time to initialize and connect to Slack's Socket Mode. Check the service:
```bash
gcloud compute ssh $(pulumi stack output vmName) --zone=$(pulumi stack output vmZone) --project=YOUR_PROJECT_ID \
  --tunnel-through-iap --command='sudo systemctl status openclaw'
```

### 403 `iam.serviceAccounts.getAccessToken` denied (Pulumi deploy fails)

This means the credentials you use to run Pulumi don't have permission to impersonate the service account. Simplest fix — run Pulumi as your user directly:
```bash
gcloud auth application-default login   # logs in as your Google account
pulumi up
```
Or grant your service account `roles/iam.serviceAccountUser` on the project.

### Connection refused on port 18789 (web dashboard)

You need an active SSH session with port forwarding open. See the **Web dashboard** section above.
