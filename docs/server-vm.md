# Server VM (headless, Slack only)

Use this if you want OpenClaw accessible only via Slack without a desktop environment. Lighter weight (`e2-medium` is enough) and no remote desktop setup needed.

---

## How it works

```
You (Slack) ──DM──▶ Slack API ──Socket Mode──▶ GCP VM (OpenClaw gateway)
                                                      │
                                               OpenRouter API
                                               (routes to Claude, GPT, etc.)
```

---

## Prerequisites

Complete the [common prerequisites](../README.md#prerequisites) first:
- GCP account, project, APIs, service account
- OpenRouter account and API key
- Slack workspace and app tokens

---

## Step 1 — Store secrets in GCP Secret Manager

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
```

**To add multiple Slack users:**
```bash
echo -n "U111AAA,U222BBB,U333CCC" | gcloud secrets versions add slack-allowed-user-ids \
  --project=${PROJECT} --data-file=-
```

> No `desktop-user-password` secret needed for the server VM.

---

## Step 2 — Create GCS bucket (optional but recommended)

The bucket stores OpenClaw data so it survives VM recreations.

```bash
cd src/infra/storage
pulumi stack init dev
pulumi up -y --cwd src/infra/storage
```

Or manually:
```bash
gcloud storage buckets create gs://YOUR_BUCKET_NAME \
  --location=US --project=YOUR_PROJECT_ID
```

---

## Step 3 — Configure Pulumi

```bash
cd src/infra/vm-server
npm install
pulumi stack init dev
```

Create `src/infra/vm-server/Pulumi.dev.yaml`:

```yaml
config:
  gcp:project: YOUR_PROJECT_ID          # e.g. my-gcp-project
  gcp:zone: us-central1-a               # change to your preferred zone

  fire-infra:machineType: e2-medium     # 1 vCPU, 4GB RAM is sufficient
  fire-infra:instanceName: fire-vm
  fire-infra:startupScriptPath: scripts/vmstartup.sh
  fire-infra:vmServiceAccountEmail: fire-provisioner@YOUR_PROJECT_ID.iam.gserviceaccount.com

  fire-infra:openrouterSecretName: openrouter-api-key
  fire-infra:slackBotSecretName: slack-bot-token
  fire-infra:slackAppSecretName: slack-app-token
  fire-infra:slackAllowedUserIdsSecretName: slack-allowed-user-ids

  fire-infra:skillsRepoUrl: https://github.com/jbadhree/fire-skills.git
  fire-infra:nodeMajorVersion: "22"
  fire-infra:openclawVersion: 2026.3.13

  fire-infra:gcsBucketName: YOUR_BUCKET_NAME
```

> `encryptionsalt` is added automatically by `pulumi stack init` — do not add it manually.

---

## Step 4 — Deploy

```bash
pulumi up -y --cwd src/infra/vm-server
```

**Monitor the startup script** (~5 minutes on first boot):
```bash
gcloud compute instances get-serial-port-output fire-vm \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```

Wait until you see: `Startup script finished. Gateway running on port 18789.`

---

## Step 5 — DM your Slack bot

Open Slack, find your bot (search by the name you gave it), and send a DM. It responds immediately — no SSH, no pairing, nothing else to do.

> **Note:** If both the server VM and desktop VM are running simultaneously with the same Slack app token, both will respond to messages. Run only one at a time if using Slack.

---

## Day-to-day usage

### Stop the VM (pause billing)
```bash
gcloud compute instances stop fire-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
```
Compute billing pauses. Disk and GCS data are retained.

### Start the VM again
```bash
gcloud compute instances start fire-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
```
OpenClaw and Slack come back up automatically in ~30 seconds.

### Update secrets (e.g. rotate API key)
```bash
echo -n "sk-or-v1-NEW-KEY" | gcloud secrets versions add openrouter-api-key \
  --project=YOUR_PROJECT_ID --data-file=-
```
Reboot to apply: `gcloud compute instances reset fire-vm --zone=us-central1-a`

### Web dashboard (optional)

**Step 1 — Get a dashboard URL with a valid auth token:**
```bash
gcloud compute ssh fire-vm --zone=us-central1-a --project=YOUR_PROJECT_ID \
  --tunnel-through-iap \
  --command='sudo -u openclaw HOME=/var/lib/openclaw npx openclaw dashboard --no-open'
```
Copy the printed URL (includes `#token=...`).

**Step 2 — Open a port-forwarding session:**
```bash
gcloud compute ssh fire-vm --zone=us-central1-a --project=YOUR_PROJECT_ID \
  --tunnel-through-iap -- -L 18789:127.0.0.1:18789
```
Keep this terminal open.

**Step 3 — Open the URL** from Step 1 in your browser.

---

## Configuration reference

| Key | Default | Description |
|-----|---------|-------------|
| `gcp:project` | — | GCP project ID (required) |
| `gcp:zone` | `us-central1-a` | VM zone |
| `machineType` | `e2-medium` | VM size |
| `instanceName` | `fire-vm` | VM name |
| `startupScriptPath` | — | Path to startup script (required) |
| `vmServiceAccountEmail` | default compute SA | SA the VM runs as |
| `openrouterSecretName` | `openrouter-api-key` | Secret for OpenRouter key |
| `slackBotSecretName` | `slack-bot-token` | Secret for Slack bot token |
| `slackAppSecretName` | `slack-app-token` | Secret for Slack app token |
| `slackAllowedUserIdsSecretName` | `slack-allowed-user-ids` | Secret for allowed Slack user IDs |
| `skillsRepoUrl` | `https://github.com/jbadhree/fire-skills.git` | Skills GitHub repo |
| `nodeMajorVersion` | `22` | Node.js major version |
| `openclawVersion` | `2026.3.13` | Pinned OpenClaw version |
| `gcsBucketName` | — | GCS bucket name |

---

## Troubleshooting

### Check startup logs
```bash
gcloud compute instances get-serial-port-output fire-vm \
  --zone=us-central1-a --project=YOUR_PROJECT_ID
```

### SSH into the VM
```bash
gcloud compute ssh fire-vm \
  --zone=us-central1-a \
  --tunnel-through-iap \
  --project=YOUR_PROJECT_ID
```

### Check OpenClaw service
```bash
systemctl status openclaw
journalctl -u openclaw -f
```

### OpenClaw not responding in Slack
Wait ~1 min after boot. Then:
```bash
systemctl status openclaw
curl http://localhost:18789/health
```

### Secret fetch failed
```bash
gcloud secrets list --project=YOUR_PROJECT_ID
gcloud secrets get-iam-policy openrouter-api-key --project=YOUR_PROJECT_ID
```
Run `pulumi up` to re-apply IAM bindings, then reboot.

### 403 `iam.serviceAccounts.getAccessToken` denied (Pulumi deploy fails)
```bash
gcloud auth application-default login
pulumi up -y --cwd src/infra/vm-server
```
