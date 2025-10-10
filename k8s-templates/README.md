# Kubernetes Templates

This directory contains Kubernetes resource templates for configuring AKS cluster nodes.

## Files

### configure-nodes.yaml

**Purpose:** Configures Azure Container Registry (ACR) credential provider on all AKS nodes with required feature gates.

**What it does:**
- Downloads and installs the Azure ACR credential provider binary
- Configures kubelet to use the credential provider for ACR authentication
- Updates kubelet configuration to use custom credential provider paths
- Enables `KubeletServiceAccountTokenForCredentialProviders` feature gate
- Uses a sentinel file to prevent duplicate configurations

**Resources:**
- **ConfigMaps:**
  - `credential-provider-config` - CredentialProviderConfig YAML for kubelet
  - `kubelet-systemd-config` - Systemd drop-in configuration (legacy)
  - `kubelet-default-config` - Kubelet extra args (legacy)
  - `nsenter-actions` - Setup scripts executed on host namespace
  
- **DaemonSet:** `setup-credential-provider`
  - Runs on all nodes
  - Uses privileged nsenter container to modify host configuration
  - InitContainer pre-copies ConfigMap files to hostPath
  - Creates sentinel file `/opt/credential-provider-configured` on success

**Usage:**
```bash
# Deploy credential provider configuration
kubectl apply -f k8s-templates/configure-nodes.yaml

# Check DaemonSet status
kubectl get daemonset setup-credential-provider

# View logs
kubectl logs -l app=setup-credential-provider
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

⚠️ **Warning:** These templates modify kubelet configuration and restart the kubelet service. This may cause temporary node disruption.

- The DaemonSet uses privileged containers with host namespace access
- Sentinel files prevent duplicate configuration runs
- Use the cleanup job before reapplying configuration changes
- Backup of original kubelet config is created at `/etc/default/kubelet.bak`

## Troubleshooting

**Check if configuration is applied:**
```bash
kubectl exec -it <daemonset-pod> -- nsenter --target 1 --mount --uts --ipc --net --pid -- \
  cat /etc/default/kubelet
```

**Check if sentinel file exists:**
```bash
kubectl exec -it <daemonset-pod> -- nsenter --target 1 --mount --uts --ipc --net --pid -- \
  ls -la /opt/credential-provider-configured
```

**View kubelet service status:**
```bash
kubectl exec -it <daemonset-pod> -- nsenter --target 1 --mount --uts --ipc --net --pid -- \
  systemctl status kubelet
```
