# NetBox Labs Orb Agent Helm Chart

This Helm chart deploys the NetBox Labs Orb Agent as a DaemonSet on Kubernetes. The agent performs network discovery and monitoring, sending telemetry data to a Diode backend via gRPC.

## Features

- **DaemonSet deployment**: Runs one agent pod per node for comprehensive network coverage
- **Security-hardened**: Uses `NET_RAW` and `NET_ADMIN` capabilities without `hostNetwork`
- **Flexible configuration**: Supports customization via values.yaml
- **Secret management**: Built-in support for Kubernetes Secrets (Vault-ready)
- **Network policies**: Optional egress restrictions for enhanced security
- **Production-ready**: Includes PodDisruptionBudget, RBAC, and resource limits

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- A running Diode instance with gRPC endpoint
- Valid Diode client credentials (ID and Secret)

## Installation

### Quick Start

1. **Add the Helm repository** (if using a Helm repo):
   ```bash
   helm repo add orb-agent https://your-repo-url
   helm repo update
   ```

2. **Create a values file** with your configuration:
   ```bash
   cat > my-values.yaml <<EOF
   diode:
     target: "grpc://diode.diode.svc.cluster.local:80/diode"

   agent:
     name: "my-k8s-cluster-agent"
     policies:
       networkDiscovery:
         enabled: true
         schedule: "*/10 * * * *"
         targets:
           - "10.0.0.0/24"
           - "192.168.1.0/24"

   credentials:
     create: true
     clientId: "your-client-id"
     clientSecret: "your-client-secret"
   EOF
   ```

3. **Install the chart**:
   ```bash
   helm install orb-agent ./charts/orb \
     -n orb-system \
     --create-namespace \
     -f my-values.yaml
   ```

### Using Existing Secrets

If you already have a Secret with credentials or want to manage secrets manually:

```yaml
credentials:
  create: false
  secretName: "existing-orb-credentials"
```

The Secret must contain:
- `DIODE_CLIENT_ID`
- `DIODE_CLIENT_SECRET`

**For ArgoCD deployments**, set `credentials.create: false` in the Application manifest to enable manual Secret management. This allows you to update secrets without triggering ArgoCD sync:

```bash
# Apply the Secret manually
kubectl apply -f argocd/applications/orb-agent-secrets.yaml

# Restart Pods to pick up changes
kubectl rollout restart daemonset/orb-agent -n netbox-orb
```

### Secure Secret Management

**For production environments**, avoid storing secrets in plain text:

#### Option 1: Sealed Secrets
```bash
kubectl create secret generic orb-diode-credentials \
  --from-literal=DIODE_CLIENT_ID=your-id \
  --from-literal=DIODE_CLIENT_SECRET=your-secret \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml

kubectl apply -f sealed-secret.yaml
```

#### Option 2: SOPS
```bash
# Encrypt your values file
sops -e my-values.yaml > my-values.enc.yaml

# Install using encrypted values
helm secrets install orb-agent ./charts/orb -f my-values.enc.yaml
```

#### Option 3: HashiCorp Vault (Future)
The chart is designed to support Vault integration. To migrate:

1. Update `agent.yaml` in ConfigMap template:
   ```yaml
   orb:
     secrets_manager:
       active: vault
       vault:
         address: "https://vault.example.com"
     backends:
       common:
         diode:
           client_id: "${vault://secret/data/orb#client_id}"
           client_secret: "${vault://secret/data/orb#client_secret}"
   ```

2. Configure Vault authentication via service account annotations.

## Configuration

### Key Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `image.repository` | Orb Agent image repository | `netboxlabs/orb-agent` |
| `image.tag` | Image tag | `latest` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `diode.target` | Diode gRPC endpoint (REQUIRED) | `""` |
| `agent.name` | Agent identifier | `k8s_orb_agent` |
| `agent.policies.networkDiscovery.enabled` | Enable network discovery | `true` |
| `agent.policies.networkDiscovery.schedule` | Cron schedule for discovery | `*/10 * * * *` |
| `agent.policies.networkDiscovery.targets` | Network CIDR ranges to scan | `["10.0.0.0/24"]` |
| `credentials.create` | Create Secret for credentials | `true` |
| `credentials.secretName` | Secret name | `orb-diode-credentials` |
| `credentials.clientId` | Diode client ID | `""` |
| `credentials.clientSecret` | Diode client secret | `""` |
| `security.runAsUser` | User ID to run containers | `0` |
| `security.capabilities` | Linux capabilities | `["NET_RAW","NET_ADMIN"]` |
| `security.allowPrivilegeEscalation` | Allow privilege escalation | `false` |
| `security.readOnlyRootFilesystem` | Make root filesystem read-only | `true` |
| `serviceAccount.create` | Create service account | `true` |
| `rbac.create` | Create RBAC resources | `true` |
| `resources.limits.cpu` | CPU limit | `500m` |
| `resources.limits.memory` | Memory limit | `512Mi` |
| `resources.requests.cpu` | CPU request | `100m` |
| `resources.requests.memory` | Memory request | `128Mi` |
| `networkPolicy.enabled` | Enable NetworkPolicy | `false` |
| `pdb.enabled` | Enable PodDisruptionBudget | `false` |
| `pdb.minAvailable` | Minimum available pods | `1` |

### Full values.yaml

See [values.yaml](./values.yaml) for all available options.

## Verification

After installation, verify the deployment:

```bash
# Check DaemonSet status
kubectl get daemonset -n orb-system

# List all agent pods
kubectl get pods -n orb-system -l app.kubernetes.io/name=orb-agent -o wide

# View logs from all pods
kubectl logs -n orb-system -l app.kubernetes.io/name=orb-agent --tail=50

# Check for Diode connection attempts
kubectl logs -n orb-system -l app.kubernetes.io/name=orb-agent | grep -i diode

# Verify security context
kubectl get pod -n orb-system -l app.kubernetes.io/name=orb-agent -o jsonpath='{.items[0].spec.containers[0].securityContext}' | jq
```

Expected output should show:
- DaemonSet with desired number matching available nodes
- Pods in `Running` state
- Logs showing connection attempts to Diode
- Security context with `NET_RAW` and `NET_ADMIN` capabilities

## Argo CD Deployment

### Example Application Manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: orb-agent
  namespace: argocd
spec:
  project: default

  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: main
    path: charts/orb
    helm:
      values: |
        diode:
          target: "grpc://diode.diode.svc.cluster.local:80/diode"

        agent:
          name: "production-k8s-agent"
          policies:
            networkDiscovery:
              enabled: true
              schedule: "*/10 * * * *"
              targets:
                - "10.0.0.0/24"
                - "172.16.0.0/16"

        credentials:
          create: true
          secretName: "orb-diode-credentials"
          # Store these in a separate encrypted values file or use Vault
          clientId: "production-client-id"
          clientSecret: "production-client-secret"

        resources:
          limits:
            cpu: 1000m
            memory: 1Gi
          requests:
            cpu: 200m
            memory: 256Mi

        networkPolicy:
          enabled: true
          egress:
            allowDNS: true

        pdb:
          enabled: true
          minAvailable: 1

        nodeSelector:
          node-role.kubernetes.io/worker: "true"

        tolerations:
          - key: "monitoring"
            operator: "Equal"
            value: "true"
            effect: "NoSchedule"

  destination:
    server: https://kubernetes.default.svc
    namespace: orb-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### Multi-Environment Setup

For different environments, create separate value files:

**values-dev.yaml**:
```yaml
agent:
  name: "dev-k8s-agent"
  policies:
    networkDiscovery:
      schedule: "*/5 * * * *"  # More frequent in dev

resources:
  limits:
    cpu: 200m
    memory: 256Mi
```

**values-prod.yaml**:
```yaml
agent:
  name: "prod-k8s-agent"
  policies:
    networkDiscovery:
      schedule: "*/30 * * * *"  # Less frequent in prod

resources:
  limits:
    cpu: 1000m
    memory: 1Gi

pdb:
  enabled: true

networkPolicy:
  enabled: true
```

Then reference in Argo CD Applications:
```yaml
source:
  helm:
    valueFiles:
      - values.yaml
      - values-prod.yaml
```

## Security Considerations

### Why Not Use hostNetwork?

This chart **explicitly avoids** `hostNetwork: true` for several security reasons:

1. **Network Isolation**: Without `hostNetwork`, pods operate in isolated network namespaces, reducing attack surface
2. **IP Address Management**: Pods get their own IP addresses, avoiding conflicts with node services
3. **Network Policy Support**: Enables fine-grained egress/ingress controls via NetworkPolicy
4. **Least Privilege**: Follows the principle of granting only necessary permissions

Instead, we use **Linux capabilities** (`NET_RAW` and `NET_ADMIN`) to enable:
- ICMP ping and traceroute for network discovery
- Raw socket access for packet analysis
- Network interface inspection

### Why Run as Root?

Currently, `runAsUser: 0` (root) is required because:
- `NET_RAW` and `NET_ADMIN` capabilities typically require root privileges in most container runtimes
- ICMP operations need elevated permissions

**Future Consideration**: With proper capability-aware binaries and newer runtimes (like crun), it may be possible to run as non-root with ambient capabilities. Test this in your environment:

```yaml
security:
  runAsUser: 1000
  runAsNonRoot: true
```

### Security Hardening

The chart implements several security best practices:

- **Read-only root filesystem**: Prevents tampering with container filesystem
- **No privilege escalation**: Blocks processes from gaining additional privileges
- **Seccomp profile**: Uses `RuntimeDefault` to restrict system calls
- **Minimal capabilities**: Drops all capabilities except required ones
- **RBAC**: Grants only necessary permissions (read Secrets/ConfigMaps)

### Network Policy

When enabled, NetworkPolicy restricts egress traffic to:
1. **DNS resolution**: UDP/TCP port 53 to kube-system namespace
2. **Diode backend**: TCP to configured Diode endpoint only

Enable with:
```yaml
networkPolicy:
  enabled: true
```

## Troubleshooting

### Pods Not Starting

Check security context:
```bash
kubectl describe pod -n orb-system -l app.kubernetes.io/name=orb-agent
```

Look for:
- `FailedCreatePodSandBox` errors (may indicate PSP/PSA restrictions)
- Capability-related errors

### Connection Issues

Verify Diode endpoint:
```bash
# Test DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup diode.diode.svc.cluster.local

# Test connectivity
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -- \
  telnet diode.diode.svc.cluster.local 80
```

### Missing Credentials

Check Secret:
```bash
kubectl get secret orb-diode-credentials -n orb-system -o yaml
```

### Permission Denied for ICMP

If logs show "permission denied" for ping/ICMP:

1. Verify capabilities are applied:
   ```bash
   kubectl get pod -n orb-system -l app.kubernetes.io/name=orb-agent -o jsonpath='{.items[0].spec.containers[0].securityContext.capabilities}'
   ```

2. Check Pod Security Standards:
   ```bash
   kubectl get namespace orb-system -o yaml | grep -A 5 pod-security
   ```

   If restricted, add label:
   ```bash
   kubectl label namespace orb-system pod-security.kubernetes.io/enforce=privileged
   ```

## Uninstallation

```bash
helm uninstall orb-agent -n orb-system

# Optionally delete the namespace
kubectl delete namespace orb-system
```

## Upgrade

```bash
helm upgrade orb-agent ./charts/orb \
  -n orb-system \
  -f my-values.yaml
```

## Development

### Template Validation

```bash
# Render templates
helm template orb-agent ./charts/orb -f my-values.yaml

# Validate against cluster
helm template orb-agent ./charts/orb -f my-values.yaml | kubectl apply --dry-run=client -f -
```

### Linting

```bash
helm lint ./charts/orb
```

## Contributing

Contributions are welcome! Please submit issues and pull requests.

## License

See LICENSE file.

## Support

For issues and questions:
- GitHub Issues: https://github.com/netboxlabs/orb-agent/issues
- Documentation: https://docs.netboxlabs.com/orb
