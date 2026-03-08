# fire

Infrastructure for a **GCP Compute Engine VM** that runs [OpenClaw](https://github.com/openclaw/openclaw) (personal AI assistant) with [OpenRouter](https://openrouter.ai) as the model provider.

## What it does

- **Pulumi** (TypeScript) provisions a single Debian VM on Google Cloud (default: `e2-medium`, zone `us-central1-a`).
- A **startup script** runs on first boot (and on recreate): installs Node.js 22, fetches the OpenRouter API key from **GCP Secret Manager**, installs OpenClaw, and runs the gateway as a systemd service on port **18789**.
- The VM’s service account is granted read access to the OpenRouter secret; the key is never stored in code or instance metadata.
- You **SSH** to the VM with gcloud and use **WebChat** by forwarding port 18789 to your machine (`-L 18789:127.0.0.1:18789`) and opening `http://localhost:18789`.

## Quick start

```bash
npm install
pulumi up
```

See **[src/infra/vms/README.md](src/infra/vms/README.md)** for one-time setup (gcloud, Pulumi config, Secret Manager), SSH, troubleshooting, and destroy/recreate.

## Repo layout

| Path | Purpose |
|------|--------|
| `src/infra/vms/index.ts` | Pulumi stack: VM, firewall, Secret Manager IAM for the OpenRouter secret. |
| `src/infra/vms/scripts/vmstartup.sh` | Startup script: Node 22, OpenClaw, OpenRouter config, systemd gateway. |
| `src/infra/vms/README.md` | Full setup and runbook. |

## Requirements

- GCP project with Secret Manager API enabled and an **OpenRouter API key** stored in a secret (e.g. `openrouter-api-key`).
- Pulumi CLI and Node.js; `gcloud` configured (or set `gcp:project` in Pulumi config).
