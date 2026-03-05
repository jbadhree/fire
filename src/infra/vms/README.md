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
pulumi config set machineType e2-micro
pulumi config set instanceName my-vm
pulumi config set imageFamily debian-12

# Optional: no external IP (VM only has private IP; use IAP to SSH)
pulumi config set assignExternalIp false

# Optional: bring VM back to same state after recreate (path used in this project)
pulumi config set startupScriptPath src/infra/vms/scripts/vmstartup.sh
# Or inline:
# pulumi config set startupScript "apt-get update && apt-get install -y curl"

# Optional: VM service account (if you hit 403 getAccessToken, set this to the same SA you use for Pulumi)
# pulumi config set vmServiceAccountEmail the-provisioner@build-and-learn.iam.gserviceaccount.com
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

Ensure your gcloud project is set (`gcloud config get-value project`) and you’re logged in (`gcloud auth list`). The stack includes a firewall rule for SSH (with external IP: from anywhere; without: only from IAP).

---

## Destroy and recreate: keeping things “back as before”

1. **Startup script** – Install packages, clone repos, and apply config so every new VM is set up the same. Set `startupScriptPath` or `startupScript` in config (or in `Pulumi.dev.yaml`).

2. **Data in GCS** – Keep persistent data in Cloud Storage instead of on the VM. In your app or startup script: read/write from `gs://your-bucket/...` (e.g. via `gsutil` or the GCS client libs). After destroy + recreate, the VM runs the startup script and your app uses the same GCS paths; no extra disk needed.

---

## Troubleshooting: 403 `iam.serviceAccounts.getAccessToken` denied

The error happens on the **first API call** (e.g. loading the zone), so it’s the **credentials Pulumi uses** (Application Default Credentials), not the VM’s service account. The identity in ADC must have **Service Account User** on the target project.

### 1. Confirm which identity is in ADC

The identity is the one you used when you ran:

```bash
gcloud auth application-default login --impersonate-service-account=YOUR_SA_EMAIL
```

That **YOUR_SA_EMAIL** is who needs the role (e.g. `the-setter-upper@sw-prod-setup.iam.gserviceaccount.com` or `the-provisioner@build-and-learn.iam.gserviceaccount.com`).

### 2. Grant that identity the role (must be done by a project admin)

A **user** who has IAM admin on `build-and-learn` (Owner or `resourcemanager.projects.setIamPolicy`) must run:

```bash
gcloud auth login
gcloud projects add-iam-policy-binding build-and-learn \
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
# Get project number for build-and-learn
PROJECT_NUMBER=$(gcloud projects describe build-and-learn --format="value(projectNumber)")

# Grant the-provisioner (or your ADC SA) permission to use the default compute SA
gcloud iam service-accounts add-iam-policy-binding \
  ${PROJECT_NUMBER}-compute@developer.gserviceaccount.com \
  --project=build-and-learn \
  --member="serviceAccount:the-provisioner@build-and-learn.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
```

### 3. Fastest workaround: use user credentials for Pulumi

If the 403 still appears after the bindings above, **skip impersonation** and run Pulumi as your **user**. Your user must have Compute Admin or Editor on `build-and-learn`.

```bash
# Log in as your user (browser); do NOT use --impersonate-service-account
gcloud auth application-default login

# Then run Pulumi; it will use your user credentials
pulumi up
```

This avoids the `getAccessToken` path entirely and usually works immediately if your user has access to the project.
