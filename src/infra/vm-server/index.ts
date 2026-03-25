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
        `Startup script not found at ${fullPath}. Check startupScriptPath (use a path relative to project root where Pulumi.yaml is, or an absolute path). ${err}`
      );
    }
  }
  return "";
}

const config = new pulumi.Config();
const project = getGcpProject(config);
const zone = config.get("gcp:zone") ?? "us-central1-a";
const machineType = config.get("machineType") ?? "e2-medium";
const diskSizeGb = config.getNumber("diskSizeGb") ?? 20;
const instanceName = config.get("instanceName") ?? "fire-vm";

// Ubuntu 22.04 LTS — consistent with vm-desktop, well-tested with gcsfuse.
const imageFamily = config.get("imageFamily") ?? "ubuntu-2204-lts";
const imageProject = config.get("imageProject") ?? "ubuntu-os-cloud";

const assignExternalIp = config.getBoolean("assignExternalIp") ?? true;
const vmServiceAccountEmail = config.get("vmServiceAccountEmail");

// OpenClaw secrets.
const openrouterSecretName = config.get("openrouterSecretName") ?? "openrouter-api-key";
const slackBotSecretName = config.get("slackBotSecretName") ?? "";
const slackAppSecretName = config.get("slackAppSecretName") ?? "";
const slackAllowedUserIdsSecretName = config.get("slackAllowedUserIdsSecretName") ?? "";

// Skills repository cloned on first boot and pulled on every boot.
const skillsRepoUrl =
  config.get("skillsRepoUrl") ?? "https://github.com/jbadhree/fire-skills.git";

// Runtime versions — pinned so the VM never auto-updates unexpectedly.
const nodeMajorVersion = config.get("nodeMajorVersion") ?? "22";
const openclawVersion = config.get("openclawVersion") ?? "2026.3.13";

// GCS bucket for persistent OpenClaw data — survives VM destroy/recreate.
// Managed by the fire-storage Pulumi program; only IAM is managed here.
const gcsBucketName = config.require("gcsBucketName");

// ── Tailscale (disabled — uncomment to re-enable) ────────────────────────────
// const tailscaleAuthKeySecretName =
//   config.get("tailscaleAuthKeySecretName") ?? "tailscale-auth-key";

// ── code-server / VS Code in browser (disabled) ──────────────────────────────
// const codeServerPasswordSecretName =
//   config.get("codeServerPasswordSecretName") ?? "code-server-password";

// Inject placeholders into startup script.
let startupScriptContent = getStartupScript(config);
if (startupScriptContent) {
  startupScriptContent = startupScriptContent
    .replace(/__PROJECT_ID__/g, project)
    .replace(/__GCS_BUCKET_NAME__/g, gcsBucketName)
    .replace(/__OPENROUTER_SECRET_NAME__/g, openrouterSecretName)
    .replace(/__SLACK_BOT_SECRET_NAME__/g, slackBotSecretName)
    .replace(/__SLACK_APP_SECRET_NAME__/g, slackAppSecretName)
    .replace(/__SLACK_ALLOWED_USER_IDS_SECRET_NAME__/g, slackAllowedUserIdsSecretName)
    .replace(/__SKILLS_REPO_URL__/g, skillsRepoUrl)
    .replace(/__NODE_MAJOR_VERSION__/g, nodeMajorVersion)
    .replace(/__OPENCLAW_VERSION__/g, openclawVersion);
  // .replace(/__TAILSCALE_AUTH_KEY_SECRET_NAME__/g, tailscaleAuthKeySecretName)
  // .replace(/__CODE_SERVER_PASSWORD_SECRET_NAME__/g, codeServerPasswordSecretName)
}

// Project number (needed for default compute SA).
const projectNumber = config.get("gcp:projectNumber") ?? (() => {
  try {
    return execSync(`gcloud projects describe ${project} --format='value(projectNumber)'`, {
      encoding: "utf-8",
    }).trim();
  } catch {
    return "";
  }
})();

function grantSecretAccess(secretId: string, member: pulumi.Input<string>, name: string) {
  return new gcp.secretmanager.SecretIamMember(name, {
    project,
    secretId,
    role: "roles/secretmanager.secretAccessor",
    member,
  });
}

const vmMembers: Array<pulumi.Input<string>> = [];
if (vmServiceAccountEmail) {
  vmMembers.push(pulumi.interpolate`serviceAccount:${vmServiceAccountEmail}`);
}
if (projectNumber) {
  vmMembers.push(`serviceAccount:${projectNumber}-compute@developer.gserviceaccount.com`);
}

// GCS bucket IAM — grant the VM's service account objectAdmin on the bucket.
const bucketIamBindings: gcp.storage.BucketIAMMember[] = [];
for (const member of vmMembers) {
  const saLabel = typeof member === "string" ? member.split("@")[0].split(":")[1] : "vm-sa";
  bucketIamBindings.push(new gcp.storage.BucketIAMMember(`server-bucket-access-${saLabel}`, {
    bucket: gcsBucketName,
    role: "roles/storage.objectAdmin",
    member,
  }));
}

// Grant each principal access to every required secret.
const secretNames = [
  openrouterSecretName,
  ...(slackBotSecretName ? [slackBotSecretName] : []),
  ...(slackAppSecretName ? [slackAppSecretName] : []),
  ...(slackAllowedUserIdsSecretName ? [slackAllowedUserIdsSecretName] : []),
  // tailscaleAuthKeySecretName,      // disabled
  // codeServerPasswordSecretName,    // disabled
];
const secretIamBindings: gcp.secretmanager.SecretIamMember[] = [];
for (const secretId of secretNames) {
  for (const member of vmMembers) {
    const saLabel = typeof member === "string" ? member.split("@")[0].split(":")[1] : "vm-sa";
    secretIamBindings.push(
      grantSecretAccess(secretId, member, `server-secret-access-${secretId}-${saLabel}`)
    );
  }
}

const vm = new gcp.compute.Instance("server-vm", {
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
    "enable-oslogin": "true",
  },
  metadataStartupScript: startupScriptContent || undefined,
  tags: ["fire-server", "ssh"],
}, { dependsOn: [...secretIamBindings, ...bucketIamBindings] });

// Allow SSH (tcp/22) only via IAP tunnel — never open to the internet.
const stack = pulumi.getStack();
const sshRule = new gcp.compute.Firewall("server-allow-ssh", {
  project,
  name: `fire-server-allow-ssh-${stack}`,
  network: "default",
  allows: [{ protocol: "tcp", ports: ["22"] }],
  sourceRanges: ["35.235.240.0/20"], // IAP CIDR for --tunnel-through-iap
  targetTags: ["ssh"],
});

export const vmName = vm.name;
export const vmId = vm.id;
export const vmZone = vm.zone;
export const externalIp = vm.networkInterfaces.apply(
  (nics: { accessConfigs?: Array<{ natIp?: string }> }[]) =>
    nics[0]?.accessConfigs?.[0]?.natIp ?? ""
);
export const selfLink = vm.selfLink;
export const bucketName = gcsBucketName;
