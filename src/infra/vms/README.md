# GCP VM (Pulumi)

Creates a single Compute Engine VM in the default VPC (external IP optional). Use a startup script so **destroy + recreate** brings the VM back to the same state; store data in GCS.

---

## One-time setup

Run these once on your machine (or when switching to a new service account / project):

```bash
# 1. Authenticate as a GCP service account (no key file; uses impersonation)
gcloud auth login 

# 2. Ensure Pulumi CLI is up to date (macOS)
brew update && brew upgrade pulumi

# 3. Install Node dependencies (from repo root)
npm install

# 4. Create the dev stack (only if you don't have one yet)
pulumi stack init dev
```

**Startup script path:** `src/infra/vms/scripts/vmstartup.sh` — set this in config or in `Pulumi.dev.yaml` as `fire-infra:startupScriptPath: src/infra/vms/scripts/vmstartup.sh`.

---

## Config (set per stack)

From repo root:

```bash
# Optional: project defaults to gcloud's current project (gcloud config get-value project)
pulumi config set gcp:project YOUR_GCP_PROJECT_ID

# Optional
pulumi config set gcp:zone us-central1-a
pulumi config set machineType e2-medium
pulumi config set instanceName my-vm
pulumi config set imageFamily debian-12

# Optional: no external IP (VM only has private IP; use IAP to SSH)
pulumi config set assignExternalIp false

# Optional: bring VM back to same state after recreate (path used in this project)
pulumi config set startupScriptPath src/infra/vms/scripts/vmstartup.sh
# Or inline:
# pulumi config set startupScript "apt-get update && apt-get install -y curl"

# Optional: VM service account (if you hit 403 getAccessToken, set this to the same SA you use for Pulumi)
# pulumi config set vmServiceAccountEmail YOUR_SA_EMAIL

# Optional: Slack channel — names of GCP Secret Manager secrets that hold Slack tokens.
# Both must be set together. See "Slack setup" section below.
# pulumi config set slackBotSecretName slack-bot-token
# pulumi config set slackAppSecretName slack-app-token
```

## Run

```bash
# From repo root
npm install
pulumi preview
pulumi up
```

Outputs: `vmName`, `vmId`, `vmZone`, `externalIp`, `selfLink`.

---

## Log in to the VM (SSH)

Use **gcloud** (it injects your SSH key and uses the right user).

**If the VM has an external IP** (default):

```bash
gcloud compute ssh $(pulumi stack output vmName) --zone $(pulumi stack output vmZone)
```

**If you set `assignExternalIp false`** (no public IP), use IAP tunneling:

```bash
gcloud compute ssh $(pulumi stack output vmName) --zone $(pulumi stack output vmZone) --tunnel-through-iap
```

**Use WebChat (port 18789):** SSH with port forwarding so `http://localhost:18789` works on your machine:

```bash
# With external IP
gcloud compute ssh $(pulumi stack output vmName) --zone $(pulumi stack output vmZone) -- -L 18789:127.0.0.1:18789

# Without external IP (IAP)
gcloud compute ssh $(pulumi stack output vmName) --zone $(pulumi stack output vmZone) --tunnel-through-iap -- -L 18789:127.0.0.1:18789
```

Keep this SSH session open while you use `http://localhost:18789`. Ensure your gcloud project is set (`gcloud config get-value project`) and you’re logged in (`gcloud auth list`). The stack includes a firewall rule for SSH (with external IP: from anywhere; without: only from IAP).

---

## Troubleshooting: SSH not connecting (connection timed out during banner exchange)

If `gcloud compute ssh` never completes and you see **Connection timed out during banner exchange** (or SSH "is not even going"):

1. **VM is overloaded** – On a small machine (e.g. `e2-micro`, 1 GB RAM), the startup script and OpenClaw can use so much CPU/memory that SSH never responds. Use **e2-medium** (4 GB) or larger:
   ```bash
   pulumi config set machineType e2-medium
   ```
   Then recreate the VM: `pulumi destroy`, then `pulumi up`.

2. **Check what's happening on the VM** (no SSH needed):
   ```bash
   gcloud compute instances get-serial-port-output fire-vm --zone=us-central1-a --project=YOUR_PROJECT
   ```
   Look for startup errors or "out of memory". If the OpenClaw service is crashing in a loop or OOM, use a larger machine type and recreate.

3. **Try again after 10–15 minutes** – First boot can take a long time; once the startup script finishes, the VM may become responsive.

---

## Troubleshooting: Connection refused on port 18789

If you see **"Connection refused"** or **"vm channel … open failed: connect failed: Connection refused"** at `http://localhost:18789`:

1. **Use an SSH session with port forwarding** (see commands above). You must have an active `gcloud compute ssh ... -- -L 18789:127.0.0.1:18789` session; opening localhost:18789 without it will fail.

2. **On the VM, check that the OpenClaw gateway is running.** In an SSH session to the VM:
   ```bash
   sudo systemctl status openclaw
   ```
   If it's not active, check logs:
   ```bash
   sudo journalctl -u openclaw -n 80 --no-pager
   cat /tmp/openclaw-startup.log
   ```

3. **Startup script may still be running.** After `pulumi up`, the first boot can take several minutes (Node 22, npm install, Secret Manager). Wait 5–10 minutes, then check:
   ```bash
   cat /tmp/openclaw-startup.log
   ```
   If the script failed (e.g. 403 reading the secret), fix Secret Manager IAM for the VM's service account and recreate the VM (`pulumi destroy` then `pulumi up`).

4. **Restart the gateway on the VM:**
   ```bash
   sudo systemctl restart openclaw
   sudo systemctl status openclaw
   ```

---

## Slack channel setup (automated)

The startup script can configure Slack automatically on every boot — no manual SSH required once set up.

### Step 1 — Create a Slack app

Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From a manifest** and paste:

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

Then:
- **Install** the app to your workspace → copy the **Bot Token** (`xoxb-...`)
- Go to **Settings → Basic Information → App-Level Tokens** → generate a token with scope `connections:write` → copy the **App Token** (`xapp-...`)
- Go to **Settings → Socket Mode** → enable it

### Step 2 — Store tokens in GCP Secret Manager

```bash
echo -n "xoxb-YOUR-BOT-TOKEN" | gcloud secrets create slack-bot-token \
  --project=YOUR_PROJECT_ID --replication-policy=automatic --data-file=-

echo -n "xapp-YOUR-APP-TOKEN" | gcloud secrets create slack-app-token \
  --project=YOUR_PROJECT_ID --replication-policy=automatic --data-file=-
```

### Step 3 — Set Pulumi config and deploy

```bash
pulumi config set slackBotSecretName slack-bot-token
pulumi config set slackAppSecretName slack-app-token
pulumi destroy && pulumi up
```

Pulumi automatically grants the VM service account access to both secrets. The startup script fetches them on every boot and writes the Slack config into `openclaw.json`.

### Step 4 — Pair yourself in Slack (once, after first deploy)

1. Open Slack, find your bot (search for it by name), and send it any DM.
2. SSH into the VM:
   ```bash
   gcloud compute ssh fire-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
   ```
3. List pending pairing requests — you'll see a code in the `Code` column:
   ```bash
   sudo -u openclaw HOME=/var/lib/openclaw npx openclaw pairing list slack
   ```
4. Approve using that code:
   ```bash
   sudo -u openclaw HOME=/var/lib/openclaw npx openclaw pairing approve slack <CODE>
   ```
   Example: `sudo -u openclaw HOME=/var/lib/openclaw npx openclaw pairing approve slack RQXHP7TW`

5. Go back to Slack and send another message — it will respond.

**This pairing is permanent.** It survives VM stop/start and service restarts. You never need to re-pair unless you recreate the VM from scratch (`pulumi destroy && pulumi up`).

After pairing, you can DM the bot from anywhere — **no SSH tunnel needed**.

---

## Stopping and starting the VM

The startup script is **idempotent**: on first boot it installs Node.js and OpenClaw (takes ~5 min); on subsequent boots it just re-fetches secrets, updates the config, and restarts the service (takes ~10 sec).

When you stop the VM, the disk persists. When you start it again, systemd auto-starts the `openclaw` service with the full config — **OpenClaw and Slack come up automatically, no action needed**. Slack pairing is stored on disk and also survives restarts.

```bash
# Stop (pauses compute billing; disk still charged ~$0.04/GB/mo)
gcloud compute instances stop fire-vm --zone=us-central1-a --project=YOUR_PROJECT_ID

# Start again
gcloud compute instances start fire-vm --zone=us-central1-a --project=YOUR_PROJECT_ID
```

After starting, wait ~30 seconds for the service to come up, then use Slack or SSH as normal.

---

## Destroy and recreate: keeping things “back as before”

1. **Startup script** – Install packages, clone repos, and apply config so every new VM is set up the same. Set `startupScriptPath` or `startupScript` in config (or in `Pulumi.dev.yaml`).

2. **Data in GCS** – Keep persistent data in Cloud Storage instead of on the VM. In your app or startup script: read/write from `gs://your-bucket/...` (e.g. via `gsutil` or the GCS client libs). After destroy + recreate, the VM runs the startup script and your app uses the same GCS paths; no extra disk needed.

---

## Troubleshooting: OpenRouter secret empty or failed to fetch

If the startup log shows **ERROR: OpenRouter secret empty or failed to fetch**, the VM cannot read the API key from Secret Manager.

**1. Ensure the secret exists and has a version** (run from your machine):

```bash
# List secrets (default name is openrouter-api-key)
gcloud secrets list --project=YOUR_PROJECT_ID

# If the secret is missing, create it and add your OpenRouter API key
gcloud secrets create openrouter-api-key --project=YOUR_PROJECT_ID --replication-policy=automatic
echo -n "YOUR_OPENROUTER_API_KEY" | gcloud secrets versions add openrouter-api-key --data-file=- --project=YOUR_PROJECT_ID
```

**2. Grant the VM's service account access to the secret.**

If you use a **custom VM service account** (e.g. `vmServiceAccountEmail` in config):

```bash
gcloud secrets add-iam-policy-binding openrouter-api-key \
  --project=YOUR_PROJECT_ID \
  --member="serviceAccount:YOUR_SA_EMAIL" \
  --role="roles/secretmanager.secretAccessor"
```

If the VM uses the **default Compute Engine service account**, get the project number and grant it:

```bash
PROJECT_NUMBER=$(gcloud projects describe YOUR_PROJECT_ID --format='value(projectNumber)')
gcloud secrets add-iam-policy-binding openrouter-api-key \
  --project=YOUR_PROJECT_ID \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

**3. Re-run the startup script on the VM** (or recreate the VM). The script only runs at first boot, so either:

- **Recreate the VM:** `pulumi destroy` then `pulumi up`, or  
- **On the VM**, run the install steps manually and start the gateway (see main README), or  
- **Re-run startup via metadata:** set the instance metadata `startup-script` again and reboot (advanced).

After fixing the secret and IAM, the next boot (or a new VM) should pass the "Fetching OpenRouter key" step.

---

## Troubleshooting: 403 `iam.serviceAccounts.getAccessToken` denied

The error happens on the **first API call** (e.g. loading the zone), so it’s the **credentials Pulumi uses** (Application Default Credentials), not the VM’s service account. The identity in ADC must have **Service Account User** on the target project.

### 1. Confirm which identity is in ADC

The identity is the one you used when you ran:

```bash
gcloud auth application-default login --impersonate-service-account=YOUR_SA_EMAIL
```

That **YOUR_SA_EMAIL** is who needs the role (e.g. `the-setter-upper@sw-prod-setup.iam.gserviceaccount.com` or `YOUR_SA_EMAIL`).

### 2. Grant that identity the role (must be done by a project admin)

A **user** who has IAM admin on `YOUR_PROJECT_ID` (Owner or `resourcemanager.projects.setIamPolicy`) must run:

```bash
gcloud auth login
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="serviceAccount:THE_EXACT_SA_EMAIL_FROM_STEP_1" \
  --role="roles/iam.serviceAccountUser"
```

If you impersonate **the-setter-upper@sw-prod-setup.iam.gserviceaccount.com**, then:

```bash
--member="serviceAccount:the-setter-upper@sw-prod-setup.iam.gserviceaccount.com"
```

You cannot run this binding while gcloud is using the impersonated SA; use your user account.

**If the 403 persists**, grant the same role on the **default Compute Engine service account** (the API sometimes checks this resource). Run as a project admin:

```bash
# Get project number for YOUR_PROJECT_ID
PROJECT_NUMBER=$(gcloud projects describe YOUR_PROJECT_ID --format="value(projectNumber)")

# Grant YOUR_SA_EMAIL (or your ADC SA) permission to use the default compute SA
gcloud iam service-accounts add-iam-policy-binding \
  ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --project=YOUR_PROJECT_ID \
  --member="serviceAccount:YOUR_SA_EMAIL" \
  --role="roles/iam.serviceAccountUser"
```

### 3. Fastest workaround: use user credentials for Pulumi

If the 403 still appears after the bindings above, **skip impersonation** and run Pulumi as your **user**. Your user must have Compute Admin or Editor on `YOUR_PROJECT_ID`.

```bash
# Log in as your user (browser); do NOT use --impersonate-service-account
gcloud auth application-default login

# Then run Pulumi; it will use your user credentials
pulumi up
```

This avoids the `getAccessToken` path entirely and usually works immediately if your user has access to the project.
