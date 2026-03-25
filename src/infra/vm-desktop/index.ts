import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";

function getGcpProject(config: pulumi.Config): string {
  const fromConfig = config.get("gcp:project");
  if (fromConfig) return fromConfig;
  try {
    const out = execSync("gcloud config get-value project --quiet", {
      encoding: "utf-8",
    }).trim();
    if (out) return out;
  } catch {
    // gcloud not installed or not logged in
  }
  throw new Error(
    "GCP project not set. Either: pulumi config set gcp:project YOUR_PROJECT_ID, or run: gcloud config set project YOUR_PROJECT_ID"
  );
}

function findPulumiProjectRoot(): string {
  let dir = __dirname;
  while (dir !== path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, "Pulumi.yaml"))) return dir;
    dir = path.dirname(dir);
  }
  return process.cwd();
}

function getStartupScript(config: pulumi.Config): string {
  const scriptPath = config.get("startupScriptPath");
  if (scriptPath) {
    const root = findPulumiProjectRoot();
    const fullPath = path.isAbsolute(scriptPath)
      ? scriptPath
      : path.join(root, scriptPath);
    try {
      return fs.readFileSync(fullPath, "utf-8");
    } catch (err) {
      throw new Error(
        `Startup script not found at ${fullPath}. Check startupScriptPath. ${err}`
      );
    }
  }
  return "";
}

const config = new pulumi.Config();
const project = getGcpProject(config);
const zone = config.get("gcp:zone") ?? "us-central1-a";

// Desktop VMs need more resources than a headless server.
const machineType = config.get("machineType") ?? "e2-standard-4";
const diskSizeGb = config.getNumber("diskSizeGb") ?? 50;
const instanceName = config.get("instanceName") ?? "fire-desktop";

// Ubuntu 22.04 LTS — best GCP support for XRDP + desktop environments.
// Use ubuntu-2404-lts for Ubuntu 24.04.
const imageFamily = config.get("imageFamily") ?? "ubuntu-2204-lts";
const imageProject = config.get("imageProject") ?? "ubuntu-os-cloud";

const assignExternalIp = config.getBoolean("assignExternalIp") ?? true;
const vmServiceAccountEmail = config.get("vmServiceAccountEmail");

// Local desktop user — name is configurable, password fetched from Secret Manager.
const desktopUsername = config.get("desktopUsername") ?? "fire";
const desktopUserPasswordSecretName =
  config.get("desktopUserPasswordSecretName") ?? "desktop-user-password";

// OpenClaw secrets — same secrets as the server VM.
const openrouterSecretName =
  config.get("openrouterSecretName") ?? "openrouter-api-key";
const slackBotSecretName =
  config.get("slackBotSecretName") ?? "slack-bot-token";
const slackAppSecretName =
  config.get("slackAppSecretName") ?? "slack-app-token";
const slackAllowedUserIdsSecretName =
  config.get("slackAllowedUserIdsSecretName") ?? "slack-allowed-user-ids";

// Skills repository cloned on first boot and pulled on every boot.
const skillsRepoUrl =
  config.get("skillsRepoUrl") ?? "https://github.com/jbadhree/fire-skills.git";

// Runtime versions — pinned so the VM never auto-updates unexpectedly.
const nodeMajorVersion = config.get("nodeMajorVersion") ?? "22";
const openclawVersion = config.get("openclawVersion") ?? "2026.3.13";

// GCS bucket for persistent desktop data — survives VM destroy/recreate.
// Mounted at ~/gcs inside the desktop session via gcsfuse.
// Managed by the fire-storage Pulumi program; only IAM is managed here.
const gcsBucketName = config.require("gcsBucketName");

// Inject placeholders into startup script.
let startupScriptContent = getStartupScript(config);
if (startupScriptContent) {
  startupScriptContent = startupScriptContent
    .replace(/__PROJECT_ID__/g, project)
    .replace(/__DESKTOP_USER__/g, desktopUsername)
    .replace(/__DESKTOP_USER_PASSWORD_SECRET_NAME__/g, desktopUserPasswordSecretName)
    .replace(/__GCS_BUCKET_NAME__/g, gcsBucketName)
    .replace(/__OPENROUTER_SECRET_NAME__/g, openrouterSecretName)
    .replace(/__SLACK_BOT_SECRET_NAME__/g, slackBotSecretName)
    .replace(/__SLACK_APP_SECRET_NAME__/g, slackAppSecretName)
    .replace(/__SLACK_ALLOWED_USER_IDS_SECRET_NAME__/g, slackAllowedUserIdsSecretName)
    .replace(/__SKILLS_REPO_URL__/g, skillsRepoUrl)
    .replace(/__NODE_MAJOR_VERSION__/g, nodeMajorVersion)
    .replace(/__OPENCLAW_VERSION__/g, openclawVersion);
}

// Project number for default compute SA.
const projectNumber = config.get("gcp:projectNumber") ?? (() => {
  try {
    return execSync(
      `gcloud projects describe ${project} --format='value(projectNumber)'`,
      { encoding: "utf-8" }
    ).trim();
  } catch {
    return "";
  }
})();

function grantSecretAccess(
  secretId: string,
  member: pulumi.Input<string>,
  name: string
) {
  return new gcp.secretmanager.SecretIamMember(name, {
    project,
    secretId,
    role: "roles/secretmanager.secretAccessor",
    member,
  });
}

const vmMembers: Array<pulumi.Input<string>> = [];
if (vmServiceAccountEmail) {
  vmMembers.push(
    pulumi.interpolate`serviceAccount:${vmServiceAccountEmail}`
  );
}
if (projectNumber) {
  vmMembers.push(
    `serviceAccount:${projectNumber}-compute@developer.gserviceaccount.com`
  );
}

// GCS bucket IAM — grant the VM's service account objectAdmin on the desktop bucket.
const bucketIamBindings: gcp.storage.BucketIAMMember[] = [];
for (const member of vmMembers) {
  const saLabel = typeof member === "string" ? member.split("@")[0].split(":")[1] : "vm-sa";
  bucketIamBindings.push(new gcp.storage.BucketIAMMember(`desktop-bucket-access-${saLabel}`, {
    bucket: gcsBucketName,
    role: "roles/storage.objectAdmin",
    member,
  }));
}

const secretNames = [
  desktopUserPasswordSecretName,
  openrouterSecretName,
  slackBotSecretName,
  slackAppSecretName,
  slackAllowedUserIdsSecretName,
];
const secretIamBindings: gcp.secretmanager.SecretIamMember[] = [];
for (const secretId of secretNames) {
  for (const member of vmMembers) {
    const saLabel =
      typeof member === "string"
        ? member.split("@")[0].split(":")[1]
        : "vm-sa";
    secretIamBindings.push(
      grantSecretAccess(
        secretId,
        member,
        `desktop-secret-access-${secretId}-${saLabel}`
      )
    );
  }
}

const vm = new gcp.compute.Instance("desktop-vm", {
  name: instanceName,
  project,
  zone,
  machineType,
  bootDisk: {
    initializeParams: {
      image: `${imageProject}/${imageFamily}`,
      size: diskSizeGb,
    },
  },
  networkInterfaces: [
    {
      network: "default",
      ...(assignExternalIp ? { accessConfigs: [{}] } : {}),
    },
  ],
  ...(vmServiceAccountEmail
    ? {
        serviceAccount: {
          email: vmServiceAccountEmail,
          scopes: ["cloud-platform"],
        },
      }
    : {}),
  metadata: {
    "pulumi-managed": "true",
    // Enable OS Login for SSH access via gcloud (optional, IAP tunnel).
    "enable-oslogin": "true",
  },
  metadataStartupScript: startupScriptContent || undefined,
  tags: ["fire-desktop", "ssh"],
}, { dependsOn: [...secretIamBindings, ...bucketIamBindings] });

// Allow SSH via IAP only — for emergency access, never direct internet.
const stack = pulumi.getStack();
const sshRule = new gcp.compute.Firewall("desktop-allow-ssh", {
  project,
  name: `fire-desktop-allow-ssh-${stack}`,
  network: "default",
  allows: [{ protocol: "tcp", ports: ["22"] }],
  sourceRanges: ["35.235.240.0/20"], // IAP CIDR
  targetTags: ["ssh"],
});

// CRD handles all remote access — no port 3389 or VPN needed.

export const vmName = vm.name;
export const vmId = vm.id;
export const vmZone = vm.zone;
export const externalIp = vm.networkInterfaces.apply(
  (nics: { accessConfigs?: Array<{ natIp?: string }> }[]) =>
    nics[0]?.accessConfigs?.[0]?.natIp ?? ""
);
export const selfLink = vm.selfLink;
export const bucketName = gcsBucketName;
export const crdNote = "Once up: visit https://remotedesktop.google.com/headless to complete one-time CRD authorization, then connect from any device at remotedesktop.google.com";
