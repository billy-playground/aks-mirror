# Troubleshooting Scripts for Configure-Node DaemonSet

This directory contains scripts to help troubleshoot and manually test the credential provider setup on AKS VMSS nodes.

## Scripts Overview

### Azure CLI Scripts (Run from your local machine)

### 1. `get-nodes.sh` - Get AKS Node Information
**Usage:** `bash get-nodes.sh <CLUSTER_NAME> <RESOURCE_GROUP>`

Gets VMSS names and instance IDs for your AKS cluster:
- Lists all VMSS in the node resource group
- Shows instance IDs and power states
- **Provides ready-to-use commands** for running scripts on nodes
- Automatically fills in cluster name, resource group, VMSS name, and instance ID

**Output includes ready-to-copy commands for:**
- Quick check on specific node
- Detailed troubleshooting on specific node
- Manual setup test on specific node
- Run on all nodes

Use this first to identify your nodes and get copy-paste ready commands.

### 2. `run-script-on-node.sh` - Run Script on Specific Node
**Usage:** `bash run-script-on-node.sh <CLUSTER_NAME> <RESOURCE_GROUP> <VMSS_NAME> <INSTANCE_ID> <SCRIPT_NAME>`

Runs a troubleshooting script on a specific node:
- Targets a single VMSS instance
- Uploads and executes the specified script
- Shows output immediately (no file download needed)
- Non-interactive execution (no confirmation prompts)
- Use VMSS_NAME and INSTANCE_ID from `get-nodes.sh` output

**Available scripts to run:**
- `troubleshoot-configure-node.sh` - Comprehensive troubleshooting
- `manual-setup.sh` - Manual setup process

### 3. `run-on-nodes.sh` - Run Script on All Nodes
**Usage:** `bash run-on-nodes.sh <CLUSTER_NAME> <RESOURCE_GROUP>`

Automatically runs a troubleshooting script on all AKS nodes:
- Discovers all VMSS instances automatically
- Uploads and executes the specified script on each node
- Default script is `troubleshoot-configure-node.sh`

### Node Scripts (Uploaded and executed by the wrapper scripts above)

### 4. `troubleshoot-configure-node.sh` - Focused Kubelet Troubleshooting
**Usage:** Run via `run-script-on-node.sh` (not directly)

Performs focused troubleshooting with emphasis on kubelet:
- Container status and logs (last 30 lines)
- Key files check (binary, config, sentinel)
- Kubelet configuration validation
- **Kubelet service status (main focus)**
- **Kubelet logs (last 50 lines)**

**Output is concise and focused** - no lengthy log files, just essential information.

### 5. `manual-setup.sh` - Manual Setup Process
**Usage:** Run via `run-script-on-node.sh` (not directly)

Manually runs the credential provider setup process:
- Downloads the credential provider binary
- Creates configuration files
- Backs up kubelet configuration
- Updates kubelet settings
- Validates configuration
- **Automatically applies changes and restarts kubelet** (no confirmation prompts)
- **Rolls back automatically** if kubelet fails to restart

Use this to test the setup process step-by-step outside of the DaemonSet. The script runs fully automated with automatic rollback on failure.

### 6. `check-kubelet-config.sh` - Check Kubelet Configuration
**Usage:** Run via `run-script-on-node.sh` (not directly)

Displays comprehensive kubelet credential provider configuration:
- **Kubelet configuration file location** and full content
- **Credential provider binary directory** path
- **Credential provider config file** path
- **Feature gates** status (especially KubeletServiceAccountTokenForCredentialProviders)
- **Binary existence check** (verifies credential provider binary)
- **Config file content** (shows actual configuration)
- **Kubelet service status**
- **Configuration summary** (quick overview of setup state)

Use this to quickly verify what paths and settings are currently configured on a node.
```