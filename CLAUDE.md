# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository manages NetBox and Orb Agent deployments on Kubernetes using ArgoCD. It contains:
- Custom NetBox Helm chart configurations with plugins (Diode, BGP)
- A custom Helm chart for NetBox Labs Orb Agent (network discovery and SNMP monitoring)
- ArgoCD Application manifests for GitOps deployment
- Custom NetBox Docker image with pre-installed plugins

## Development Environment

- **Language**: Japanese is preferred for responses (開発者は日本語話者なので日本語で答えること)
- **Platform**: Debian Bullseye-based container
- **Kubernetes Access**: Available via MCP server tools
- **ArgoCD Access**: Available via MCP server and environment variables in `.env`

## Important Restrictions

1. **DO NOT** run `git push` - Request user to do this (environment limitation)
2. **DO NOT** run `kubectl apply` - Managed by ArgoCD, request user to sync instead
3. **Always ask for confirmation** before performing destructive operations via MCP servers
4. **Prefer MCP server operations** whenever possible over direct CLI commands

## Key Commands

### Helm Chart Development

```bash
# Render Helm templates with values
helm template orb-agent ./charts/orb -f <values-file>

# Validate templates against cluster schema
helm template orb-agent ./charts/orb -f <values-file> | kubectl apply --dry-run=client -f -

# Lint the Helm chart
helm lint ./charts/orb
```

### Docker Image Build

```bash
# Build custom NetBox image (from ./docker/netbox-custom)
docker build -t ghcr.io/zinntikumugai/netbox-custom:latest ./docker/netbox-custom

# Image includes:
# - NetBox v4.4.4-3.4.1
# - netboxlabs-diode-netbox-plugin (v1.4.1)
# - netbox-bgp (v0.17.0)
```

### ArgoCD Operations (via MCP)

Use MCP ArgoCD tools instead of kubectl commands:
- Get application status: `mcp__argocd-mcp-stdio__get_application`
- Sync operations should be requested through user

## Architecture

### Repository Structure

```
.
├── argocd/applications/     # ArgoCD Application manifests
│   ├── netbox*.yaml        # NetBox and Diode applications
│   └── orb-agent*.yaml     # Orb Agent applications and secrets
├── charts/orb/             # Custom Helm chart for Orb Agent
│   ├── templates/          # Kubernetes resource templates
│   ├── values.yaml         # Default values
│   └── Chart.yaml          # Chart metadata
├── docker/netbox-custom/   # Custom NetBox Docker image
│   └── Dockerfile          # Multi-plugin NetBox image
└── netbox-app.yaml         # Root ArgoCD Application (App of Apps)
```

### Orb Agent Helm Chart Architecture

The Orb Agent chart deploys a DaemonSet that runs network and SNMP discovery:

**Key Design Patterns**:
1. **Init Container Pattern**: Uses busybox init container to expand environment variables in config
   - Template ConfigMap contains `${DIODE_CLIENT_ID}` and `${DIODE_CLIENT_SECRET}` placeholders
   - Init container reads credentials from Secret, expands variables via `sed`, writes to emptyDir
   - Main container reads expanded config from emptyDir volume
   - This solves the read-only filesystem constraint while keeping credentials secure

2. **Security Hardening**:
   - `runAsUser: 0` with `NET_RAW` and `NET_ADMIN` capabilities (required for ICMP/network ops)
   - `readOnlyRootFilesystem: true` with emptyDir mounts for `/tmp` and `/var/run`
   - `allowPrivilegeEscalation: false`
   - Drops all capabilities except required ones

3. **Secret Management**:
   - `credentials.create: true` - Chart manages Secret (dev/testing)
   - `credentials.create: false` - External Secret management (production with ArgoCD)
   - When using ArgoCD, apply secrets separately: `kubectl apply -f argocd/applications/orb-agent-secrets.yaml`
   - Restart DaemonSet after secret changes: `kubectl rollout restart daemonset/orb-agent -n netbox-orb`

**Configuration Structure** (charts/orb/templates/configmap.yaml:8-93):
- `orb.backends`: Network discovery and SNMP backends config
- `orb.backends.common.diode`: Diode gRPC target and OAuth2 credentials
- `orb.policies`: Discovery schedules, targets, and authentication

**Template Files**:
- `daemonset.yaml`: Main workload with init container for config expansion
- `configmap.yaml`: Agent config with variable placeholders
- `secret.yaml`: Conditional Secret creation
- `rbac.yaml`, `serviceaccount.yaml`: RBAC for Secret/ConfigMap access
- `networkpolicy.yaml`, `pdb.yaml`: Optional security/availability features

### NetBox Deployment

**Custom Image** (docker/netbox-custom/Dockerfile:2-13):
- Base: `netboxcommunity/netbox:v4.4.4-3.4.1`
- Uses `uv` package manager for fast plugin installation
- Pre-installs `netboxlabs-diode-netbox-plugin` and `netbox-bgp`

**ArgoCD Configuration** (argocd/applications/netbox.yaml):
- Source: Official NetBox Helm chart from `charts.netbox.oss.netboxlabs.com`
- Custom image: `ghcr.io/zinntikumugai/netbox-custom:latest`
- PostgreSQL subchart with custom labels to avoid PDB conflicts
- External Secret management for PostgreSQL credentials

**Plugin Configuration**:
- `netbox_diode_plugin.diode_target_override`: Points to Ingress-Nginx controller for gRPC
- `netbox_bgp`: Enables BGP peering management in NetBox

### Diode Architecture

**Component Communication**:
```
Orb Agent (DaemonSet)
    ↓ gRPC via grpc://
NetBox Diode Ingress-Nginx Controller (netbox-diode.svc.cluster.local:80)
    ↓
Diode Service
    ↓ gRPC
NetBox with Diode Plugin
```

**Key Points**:
- Orb Agent sends telemetry via gRPC to Diode
- Diode uses OAuth2 authentication (client_id/client_secret)
- NetBox Diode plugin processes and stores data in NetBox

## Common Workflows

### Updating Orb Agent Configuration

1. Modify `argocd/applications/orb-agent.yaml` in the `helm.values` section
2. Commit changes - ArgoCD will auto-sync (automated: prune + selfHeal enabled)
3. If secrets changed, update manually:
   ```bash
   kubectl apply -f argocd/applications/orb-agent-secrets.yaml
   kubectl rollout restart daemonset/orb-agent -n netbox-orb
   ```

### Adding New Discovery Targets

Edit `argocd/applications/orb-agent.yaml` → `agent.policies.networkDiscovery.targets`:
```yaml
agent:
  policies:
    networkDiscovery:
      targets:
        - "172.16.0.0/16"    # Existing
        - "192.168.10.0/24"  # Existing
        - "10.0.0.0/8"       # New
```

### Updating NetBox Plugins

1. Modify `docker/netbox-custom/Dockerfile` to change plugin versions
2. Build and push new image
3. Image pull policy is `Always`, so restart NetBox pods or update tag

### Troubleshooting Orb Agent

```bash
# View agent logs
kubectl logs -n netbox-orb -l app.kubernetes.io/name=orb-agent --tail=50

# Check for Diode connectivity issues
kubectl logs -n netbox-orb -l app.kubernetes.io/name=orb-agent | grep -i diode

# Verify init container expanded config correctly
kubectl logs -n netbox-orb <pod-name> -c config-init

# Check capabilities
kubectl get pod -n netbox-orb -l app.kubernetes.io/name=orb-agent -o jsonpath='{.items[0].spec.containers[0].securityContext.capabilities}'

# Verify secret exists
kubectl get secret orb-diode-credentials -n netbox-orb -o yaml
```

## Critical Configurations

### Orb Agent Values Hierarchy
- Base defaults: `charts/orb/values.yaml`
- Override in ArgoCD: `argocd/applications/orb-agent.yaml` (helm.values section)
- Secrets: `argocd/applications/orb-agent-secrets.yaml` (manual kubectl apply)

### Network Discovery Settings
- **schedule**: Cron expression (e.g., `*/10 * * * *` = every 10 minutes)
- **targets**: CIDR ranges for scanning
- **scope.fastMode**: Uses aggressive timing for faster scans
- **scope.icmpEcho**: Enables ping-based discovery
- **scope.timing**: Nmap timing template (0-5, higher = faster but more detectable)

### SNMP Discovery Settings
- **authentication.protocolVersion**: `SNMPv2c` or `SNMPv3`
- **authentication.community**: Community string for SNMPv2c
- For SNMPv3: username, securityLevel (NoAuthNoPriv/AuthNoPriv/AuthPriv), authProtocol/Passphrase, privProtocol/Passphrase

## References

- NetBox Diode Plugin: https://docs.netboxlabs.com/orb
- Orb Agent: https://github.com/netboxlabs/orb-agent
- NetBox BGP Plugin: https://github.com/netbox-community/netbox-bgp
- Helm Chart README: `charts/orb/README.md` (comprehensive deployment guide)
