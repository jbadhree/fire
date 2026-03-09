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
  const inline = config.get("startupScript");
  if (inline) return inline;
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
const instanceName = config.get("instanceName") ?? "fire-vm";
const imageFamily = config.get("imageFamily") ?? "debian-12";
const assignExternalIp = config.getBoolean("assignExternalIp") ?? true;
const vmServiceAccountEmail = config.get("vmServiceAccountEmail");
const openrouterSecretName = config.get("openrouterSecretName") ?? "openrouter-api-key";
// Optional: Slack bot + app tokens stored in Secret Manager.
// Leave unset to skip Slack setup. Set to enable fully-automated Slack channel.
const slackBotSecretName = config.get("slackBotSecretName") ?? "";
const slackAppSecretName = config.get("slackAppSecretName") ?? "";
// Optional: name of a Secret Manager secret holding comma-separated Slack user IDs
// allowed to DM the bot without pairing. e.g. secret value "U0AK770CMM0".
const slackAllowedUserIdsSecretName = config.get("slackAllowedUserIdsSecretName") ?? "";

// Inject project and secret names into startup script placeholders.
let startupScriptContent = getStartupScript(config);
if (startupScriptContent) {
  startupScriptContent = startupScriptContent
    .replace(/__PROJECT_ID__/g, project)
    .replace(/__OPENROUTER_SECRET_NAME__/g, openrouterSecretName)
    .replace(/__SLACK_BOT_SECRET_NAME__/g, slackBotSecretName)
    .replace(/__SLACK_APP_SECRET_NAME__/g, slackAppSecretName)
    .replace(/__SLACK_ALLOWED_USER_IDS_SECRET_NAME__/g, slackAllowedUserIdsSecretName);
}
const metadataStartupScript = startupScriptContent || undefined;

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

// Grant a service account secretAccessor on a given secret.
function grantSecretAccess(secretId: string, member: pulumi.Input<string>, name: string) {
  return new gcp.secretmanager.SecretIamMember(name, {
    project,
    secretId,
    role: "roles/secretmanager.secretAccessor",
    member,
  });
}

// Build the list of principals that need secret access.
const vmMembers: Array<pulumi.Input<string>> = [];
if (vmServiceAccountEmail) {
  vmMembers.push(pulumi.interpolate`serviceAccount:${vmServiceAccountEmail}`);
}
if (projectNumber) {
  vmMembers.push(`serviceAccount:${projectNumber}-compute@developer.gserviceaccount.com`);
}

// Grant each principal access to every required secret.
const secretIamBindings: gcp.secretmanager.SecretIamMember[] = [];
const secretNames = [
  openrouterSecretName,
  ...(slackBotSecretName ? [slackBotSecretName] : []),
  ...(slackAppSecretName ? [slackAppSecretName] : []),
  ...(slackAllowedUserIdsSecretName ? [slackAllowedUserIdsSecretName] : []),
];
for (const secretId of secretNames) {
  for (const member of vmMembers) {
    const saLabel = typeof member === "string" ? member.split("@")[0].split(":")[1] : "vm-sa";
    secretIamBindings.push(grantSecretAccess(secretId, member, `secret-access-${secretId}-${saLabel}`));
  }
}

const vm = new gcp.compute.Instance("vm", {
  name: instanceName,
  project,
  zone,
  machineType,
  bootDisk: {
    initializeParams: {
      image: `debian-cloud/${imageFamily}`,
      size: 10,
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
  },
  metadataStartupScript: metadataStartupScript,
  tags: ["fire-infra", "ssh"],
}, { dependsOn: secretIamBindings });

// Allow SSH (tcp/22) only via IAP tunnel — requires gcloud auth, never open to internet.
const sshSourceRanges = ["35.235.240.0/20"]; // IAP CIDR for --tunnel-through-iap
const stack = pulumi.getStack();
const sshRule = new gcp.compute.Firewall("allow-ssh", {
  project,
  name: `fire-infra-allow-ssh-${stack}`,
  network: "default",
  allows: [{ protocol: "tcp", ports: ["22"] }],
  sourceRanges: sshSourceRanges,
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
