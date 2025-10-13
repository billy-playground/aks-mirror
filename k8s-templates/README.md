# Kubernetes Templates

This directory contains Kubernetes resource templates for configuring AKS cluster nodes.

## Files

### configure-nodes.yaml

**Purpose:** Configures Azure Container Registry (ACR) credential provider on all AKS nodes to enable pulling images from custom ACR registries using custom credential provider paths instead of AKS defaults.

**What it does:**
1. **Downloads Azure ACR credential provider binary** from GitHub (architecture-specific: amd64/arm64)
2. **Generates credential provider configuration** dynamically
3. **Updates kubelet configuration** to use custom paths:
   - Changes binary directory: `/var/lib/kubelet/credential-provider` → `/opt`
   - Changes config path: `/var/lib/kubelet/credential-provider-config.yaml` → `/etc/kubernetes/credential-provider/credential-provider-config.yaml`
5. **Adds feature gate:** `KubeletServiceAccountTokenForCredentialProviders=true`
6. **Validates all changes** with 6 validation checks before applying
7. **Restarts kubelet** service to apply changes
8. **Creates sentinel file** to prevent duplicate configurations

**Key Features:**
- ✅ **Comprehensive Validation:** 6 validation checks ensure configuration correctness
- ✅ **Automatic Backup:** Creates `/etc/default/kubelet.bak` before modifications
- ✅ **Automatic Rollback:** Restores backup if kubelet fails to restart
- ✅ **Detailed Logging:** Shows original config, updated config, and diff
- ✅ **Architecture Detection:** Automatically detects amd64/arm64 and downloads correct binary
- ✅ **Dynamic Configuration:** Generates YAML configuration at runtime instead of static ConfigMaps
- ✅ **Idempotent:** Sentinel file prevents re-running on already configured nodes

**Resources:**
- **ConfigMap:** `nsenter-actions`
  - Contains the bash setup script executed in host namespace
  - Script is architecture-aware and handles both amd64 and arm64
  
- **DaemonSet:** `setup-credential-provider`
  - Runs on all nodes using `hostNetwork` and `hostPID`
  - Uses `docker.io/alexeldeib/nsenter:latest` image
  - Custom entrypoint to work around image bug
  - Mounts ConfigMap to `/opt/actions` and hostPath to `/mnt/actions`
  - Executes script via `nsenter` in host's mount/uts/ipc/net/pid namespaces

**Configuration Generated:**
```yaml
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
- name: acr-credential-provider
  matchImages:
  - "*.azurecr.io"
  - "*.azurecr.cn"
  - "*.azurecr.de"
  - "*.azurecr.us"
  defaultCacheDuration: "10m"
  apiVersion: credentialprovider.kubelet.k8s.io/v1
  exec:
    command: /opt/azure-acr-credential-provider
    apiVersion: credentialprovider.kubelet.k8s.io/v1
```

**Usage:**

**1. Deploy Configuration:**
```bash
# Apply the template
kubectl apply -f k8s-templates/configure-nodes.yaml

# Check DaemonSet status
kubectl get daemonset setup-credential-provider
kubectl get pods -l app=setup-credential-provider

# Monitor installation logs
kubectl logs -l app=setup-credential-provider -f

# Check all pods completed successfully
kubectl get pods -l app=setup-credential-provider
```

**2. Verification:**
```bash
# Check credential provider binary exists
kubectl exec -it <pod-name> -- nsenter -t 1 -m ls -la /opt/azure-acr-credential-provider

# Check credential provider config
kubectl exec -it <pod-name> -- nsenter -t 1 -m cat /etc/kubernetes/credential-provider/credential-provider-config.yaml

# Check kubelet configuration
kubectl exec -it <pod-name> -- nsenter -t 1 -m cat /etc/default/kubelet

# Check kubelet service status
kubectl exec -it <pod-name> -- nsenter -t 1 -m systemctl status kubelet
```

---

### cleanup-credential-provider.yaml

**Purpose:** Removes credential provider sentinel files to allow reconfiguration.

**What it does:**
- Runs a Job that removes `/opt/credential-provider-configured` from each node
- Allows the DaemonSet to reconfigure nodes if needed

**Resources:**
- **ConfigMap:** `cleanup-actions` - Cleanup script
- **Job:** `cleanup-credential-provider`
  - Runs with `completions: 3` and `parallelism: 3` (one per node)
  - Uses pod anti-affinity to distribute across nodes
  - Uses nsenter to access host filesystem

**Usage:**
```bash
# Run cleanup to reset configuration
kubectl apply -f k8s-templates/cleanup-credential-provider.yaml

# Check Job status
kubectl get job cleanup-credential-provider

# View cleanup logs
kubectl logs -l app=cleanup-credential-provider

# After cleanup, restart DaemonSet pods to reconfigure
kubectl delete pods -l app=setup-credential-provider
```

## Prerequisites

- AKS cluster with workload identity enabled
- Cluster admin permissions
- Nodes must support privileged containers

## Important Notes

⚠️ **Warning:** These templates modify kubelet configuration and restart the kubelet service. This will cause temporary node disruption.

**Safety Features:**
- ✅ **Automatic backup** - Creates `/etc/default/kubelet.bak` before changes
- ✅ **Validation checks** - 6 checks ensure configuration correctness
- ✅ **Automatic rollback** - Restores backup if kubelet restart fails
- ✅ **Sentinel file** - Prevents duplicate configuration runs
- ✅ **Idempotent** - Safe to reapply, already configured nodes are skipped

**Architecture Support:**
- ✅ **amd64** (x86_64)
- ✅ **arm64** (aarch64)

**Dependencies:**
- The DaemonSet uses privileged containers with host namespace access
- Requires cluster admin permissions
- Downloads azure-acr-credential-provider binary from GitHub

## Troubleshooting

### View Installation Logs

```bash
# Get complete installation logs
kubectl logs -l app=setup-credential-provider --tail=200

# Check specific sections
kubectl logs <pod> | grep -A10 "ORIGINAL KUBELET CONFIGURATION"
kubectl logs <pod> | grep -A10 "UPDATED KUBELET CONFIGURATION"
kubectl logs <pod> | grep -A10 "CONFIGURATION DIFF"
kubectl logs <pod> | grep -A10 "VALIDATION CHECKS"
```

### Configuration Issues

**Check if configuration is already applied:**
```bash
# View current kubelet config
kubectl exec -it <pod> -- nsenter -t 1 -m cat /etc/default/kubelet | grep image-credential-provider

# Check if sentinel file exists (indicates already configured)
kubectl exec -it <pod> -- nsenter -t 1 -m ls -la /opt/credential-provider-configured
```

**Check credential provider binary:**
```bash
# Verify binary exists and is executable
kubectl exec -it <pod> -- nsenter -t 1 -m ls -la /opt/azure-acr-credential-provider

# Check binary architecture
kubectl exec -it <pod> -- nsenter -t 1 -m file /opt/azure-acr-credential-provider
```

**Check credential provider config:**
```bash
# View generated config
kubectl exec -it <pod> -- nsenter -t 1 -m cat /etc/kubernetes/credential-provider/credential-provider-config.yaml
```

**View kubelet service status:**
```bash
# Check if kubelet is running
kubectl exec -it <pod> -- nsenter -t 1 -m systemctl status kubelet --no-pager

# View recent kubelet logs
kubectl exec -it <pod> -- nsenter -t 1 -m journalctl -u kubelet -n 50 --no-pager
```

### Recovery

**Restore original kubelet configuration:**
```bash
# If backup exists, restore it
kubectl exec -it <pod> -- nsenter -t 1 -m cp /etc/default/kubelet.bak /etc/default/kubelet
kubectl exec -it <pod> -- nsenter -t 1 -m systemctl restart kubelet
```

**Remove sentinel file to allow reconfiguration:**
```bash
# Remove sentinel to allow DaemonSet to reconfigure
kubectl exec -it <pod> -- nsenter -t 1 -m rm -f /opt/credential-provider-configured

# Delete and recreate pods
kubectl delete pods -l app=setup-credential-provider
```

### Common Error Messages

**"bash: /opt/actions/setup-credential-provider: No such file or directory"**
- This was an old issue, fixed by custom entrypoint
- If you see this, ensure you're using the latest configure-nodes.yaml

**"ERROR: Validation failed!"**
- Check the specific validation that failed in the logs
- Review the TEMP_FILE content shown in error output
- May indicate sed commands didn't work as expected

**"Kubelet failed to restart"**
- Configuration is automatically rolled back
- Check kubelet logs: `journalctl -u kubelet -n 100`
- Verify kubelet config syntax is correct

## Development

**Testing changes:**
```bash
# Make changes to the script in ConfigMap
kubectl edit configmap nsenter-actions

# Delete pods to re-run with new script
kubectl delete pods -l app=setup-credential-provider

# Watch logs in real-time
kubectl logs -l app=setup-credential-provider -f
```

**Script structure:**
1. Check sentinel file (skip if already configured)
2. Architecture detection (amd64/arm64)
3. Directory creation
4. Binary download
5. Configuration generation
6. Kubelet config analysis and modification
7. Validation (6 checks)
8. Apply configuration
9. Kubelet restart with rollback on failure
10. Sentinel file creation

**Validation checks performed:**
1. ✓ Credential provider config path present
2. ✓ Credential provider bin dir present
3. ✓ Feature gate present
4. ✓ KUBELET_FLAGS line valid
5. ✓ Old config path removed
6. ✓ Old bin dir removed
