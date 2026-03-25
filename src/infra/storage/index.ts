import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";
import { execSync } from "child_process";

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

const config = new pulumi.Config();
const project = getGcpProject(config);

// Bucket name must be globally unique. Recommended: include your project name.
// Example: badhree-openclaw-data
const bucketName = config.require("gcsBucketName");

// Location: "US" (multi-region, higher availability + cost) or a single region
// like "us-central1" (lower cost, same region as VM).
const location = config.get("location") ?? "US";

const bucket = new gcp.storage.Bucket("openclaw-data", {
  name: bucketName,
  project,
  location,

  // Uniform bucket-level access: simpler IAM model, no per-object ACLs.
  uniformBucketLevelAccess: true,

  // Versioning: keeps previous versions of objects.
  // Protects against accidental overwrites to openclaw.json and session data.
  versioning: {
    enabled: true,
  },

  // Lifecycle rules: automatically clean up old non-current versions.
  // Keeps the last 10 versions and deletes non-current versions older than 90 days.
  lifecycleRules: [
    {
      action: { type: "Delete" },
      condition: {
        numNewerVersions: 10,
        withState: "ARCHIVED",
      },
    },
    {
      action: { type: "Delete" },
      condition: {
        daysSinceNoncurrentTime: 90,
        withState: "ARCHIVED",
      },
    },
  ],

  // Do not allow public access to the bucket.
  publicAccessPrevention: "enforced",

  // forceDestroy: true — allows `pulumi destroy` to delete the bucket even
  // when it contains objects. All OpenClaw data (config, memory, logs) will be
  // permanently deleted. Set to false if you want to protect data on destroy.
  forceDestroy: true,
});

export const name = bucket.name;
export const url = bucket.url;
export const selfLink = bucket.selfLink;
