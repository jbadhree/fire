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
const machineType = config.get("machineType") ?? "e2-micro";
const instanceName = config.get("instanceName") ?? "fire-vm";
const imageFamily = config.get("imageFamily") ?? "debian-12";
const assignExternalIp = config.getBoolean("assignExternalIp") ?? true;
const vmServiceAccountEmail = config.get("vmServiceAccountEmail");
const openrouterSecretName =
  config.get("openrouterSecretName") ?? "openrouter-api-key";

// Inject project and secret name into startup script (placeholders __PROJECT_ID__ and __OPENROUTER_SECRET_NAME__).
let startupScriptContent = getStartupScript(config);
if (startupScriptContent) {
  startupScriptContent = startupScriptContent
    .replace(/__PROJECT_ID__/g, project)
    .replace(/__OPENROUTER_SECRET_NAME__/g, openrouterSecretName);
}
const metadataStartupScript = startupScriptContent || undefined;

// Grant VM service account access to the OpenRouter API key in Secret Manager (secret must already exist).
if (vmServiceAccountEmail) {
  new gcp.secretmanager.SecretIamMember("openrouter-secret-access", {
    project,
    secretId: openrouterSecretName,
    role: "roles/secretmanager.secretAccessor",
    member: pulumi.interpolate`serviceAccount:${vmServiceAccountEmail}`,
  });
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
});

// Allow SSH (tcp/22). With external IP: from anywhere. Without: only via IAP tunnel.
const sshSourceRanges = assignExternalIp
  ? ["0.0.0.0/0"]
  : ["35.235.240.0/20"]; // IAP CIDR for --tunnel-through-iap
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
