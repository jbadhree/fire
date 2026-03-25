import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { execSync } from "child_process";

// ── Run this program ONCE after creating a GCP project and enabling billing. ──
//
// What it does:
//   1. Enables all GCP APIs the other programs need
//   2. Creates a dedicated provisioner service account
//   3. Grants it exactly the roles required to run vm-desktop, vm-server, storage
//
// How to run:
//   gcloud auth application-default login   (your own Google account, must have Owner/Editor)
//   pulumi stack init dev --cwd src/infra/setup
//   pulumi up -y --cwd src/infra/setup
//
// After this succeeds, copy the `serviceAccountEmail` output into all other
// Pulumi.dev.yaml files as `vmServiceAccountEmail`.

function getGcpProject(config: pulumi.Config): string {
  const fromConfig = config.get("gcp:project");
  if (fromConfig) return fromConfig;
  try {
    const out = execSync("gcloud config get-value project --quiet", {
      encoding: "utf-8",
    }).trim();
    if (out) return out;
  } catch {
    // gcloud not installed or not configured
  }
  throw new Error(
    "GCP project not set. Run: gcloud config set project YOUR_PROJECT_ID  " +
    "or add 'gcp:project: YOUR_PROJECT_ID' to Pulumi.dev.yaml"
  );
}

const config = new pulumi.Config();
const project = getGcpProject(config);

const saName = config.get("serviceAccountName") ?? "fire-provisioner";
const saDisplayName = config.get("serviceAccountDisplayName") ?? "Fire infrastructure provisioner";

// ── APIs ──────────────────────────────────────────────────────────────────────
// disableOnDestroy: false — don't disable APIs when running `pulumi destroy`.
// Disabling APIs can break other resources in the project; leave cleanup manual.

const apis = [
  { name: "compute",             api: "compute.googleapis.com" },
  { name: "secretmanager",       api: "secretmanager.googleapis.com" },
  { name: "iam",                 api: "iam.googleapis.com" },
  { name: "iamcredentials",      api: "iamcredentials.googleapis.com" },
  { name: "storage",             api: "storage.googleapis.com" },
  { name: "cloudresourcemanager", api: "cloudresourcemanager.googleapis.com" },
  // IAP TCP forwarding — enables `gcloud compute ssh --tunnel-through-iap`
  // so VMs don't need public SSH ports.
  { name: "iap",                 api: "iap.googleapis.com" },
  // OS Login — links SSH public keys to Google accounts, no manual key management.
  { name: "oslogin",             api: "oslogin.googleapis.com" },
];

const enabledApis = apis.map(({ name, api }) =>
  new gcp.projects.Service(`api-${name}`, {
    project,
    service: api,
    disableOnDestroy: false,
  })
);

// ── Service account ───────────────────────────────────────────────────────────
// This SA is attached to all VMs as their identity. It is also the SA that
// Pulumi impersonates when deploying other stacks (vm-desktop, vm-server, storage).

const sa = new gcp.serviceaccount.Account("provisioner-sa", {
  project,
  accountId: saName,
  displayName: saDisplayName,
}, {
  dependsOn: enabledApis,
});

// ── IAM roles ─────────────────────────────────────────────────────────────────

const roles = [
  // Create and manage VMs, disks, firewall rules, networks.
  "roles/compute.admin",

  // Create secrets, manage secret versions, grant other identities access.
  "roles/secretmanager.admin",

  // Create and manage GCS buckets, set bucket-level IAM policies.
  "roles/storage.admin",

  // Required when creating a VM: attaches the SA identity to the instance.
  "roles/iam.serviceAccountUser",

  // Read project metadata (project number lookup used by Pulumi GCP provider).
  "roles/browser",
];

const iamBindings = roles.map((role) =>
  new gcp.projects.IAMMember(`iam-${role.replace(/\//g, "-")}`, {
    project,
    role,
    member: pulumi.interpolate`serviceAccount:${sa.email}`,
  })
);

// ── Outputs ───────────────────────────────────────────────────────────────────

export const serviceAccountEmail = sa.email;
export const serviceAccountName = sa.name;

export const nextSteps = pulumi.interpolate`
Setup complete. Next steps:

1. Copy this service account email into every Pulumi.dev.yaml:
     vmServiceAccountEmail: ${sa.email}

2. Deploy the GCS bucket:
     pulumi up -y --cwd src/infra/storage

3. Deploy the desktop VM:
     pulumi up -y --cwd src/infra/vm-desktop

4. (Optional) Deploy the server VM:
     pulumi up -y --cwd src/infra/vm-server
`;
