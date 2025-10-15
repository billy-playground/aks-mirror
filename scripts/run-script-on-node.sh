#!/bin/bash

# Script to upload and run troubleshooting scripts on specific AKS nodes
# Usage: bash run-script-on-node.sh <CLUSTER_NAME> <RESOURCE_GROUP> <VMSS_NAME> <INSTANCE_ID> <SCRIPT_NAME>

set -e

if [ $# -lt 5 ]; then
    echo "Usage: $0 <CLUSTER_NAME> <RESOURCE_GROUP> <VMSS_NAME> <INSTANCE_ID> <SCRIPT_NAME>"
    echo ""
    echo "Parameters:"
    echo "  CLUSTER_NAME - Name of the AKS cluster"
    echo "  RESOURCE_GROUP - Resource group containing the cluster"  
    echo "  VMSS_NAME - Name of the VMSS (from get-nodes.sh output)"
    echo "  INSTANCE_ID - Instance ID (from get-nodes.sh output)"
    echo "  SCRIPT_NAME - Script to run (quick-check.sh, troubleshoot-configure-node.sh, etc.)"
    echo ""
    echo "Example:"
    echo "  $0 my-cluster my-rg aks-nodepool1-12345678-vmss 0 quick-check.sh"
    echo ""
    echo "First run get-nodes.sh to get VMSS names and instance IDs"
    exit 1
fi

CLUSTER_NAME="$1"
RESOURCE_GROUP="$2"
VMSS_NAME="$3"
INSTANCE_ID="$4"
SCRIPT_NAME="$5"

echo "========================================"
echo "Run Script on AKS Node"
echo "========================================"
echo "Cluster: $CLUSTER_NAME"
echo "Resource Group: $RESOURCE_GROUP"
echo "VMSS: $VMSS_NAME"
echo "Instance ID: $INSTANCE_ID"
echo "Script: $SCRIPT_NAME"
echo ""

# Check if Azure CLI is logged in
if ! az account show &>/dev/null; then
    echo "Error: Not logged into Azure CLI. Run 'az login' first."
    exit 1
fi

# Get node resource group
echo "Getting cluster information..."
NODE_RESOURCE_GROUP=$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query 'nodeResourceGroup' -o tsv)

if [ -z "$NODE_RESOURCE_GROUP" ]; then
    echo "Error: Could not find node resource group for cluster $CLUSTER_NAME"
    exit 1
fi

echo "✓ Node Resource Group: $NODE_RESOURCE_GROUP"

# Check if the script file exists locally
SCRIPT_PATH="$(dirname "$0")/$SCRIPT_NAME"
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Script file not found: $SCRIPT_PATH"
    echo "Available scripts:"
    ls -la "$(dirname "$0")"/*.sh 2>/dev/null || echo "No .sh files found in $(dirname "$0")"
    exit 1
fi

echo "✓ Found script: $SCRIPT_PATH"

# Create the command that will upload and run the script
echo ""
echo "Creating command to upload and execute script..."

# Read and encode the script
SCRIPT_CONTENT=$(base64 -w 0 "$SCRIPT_PATH")

# Create the remote execution command
REMOTE_COMMAND=$(cat << EOF
#!/bin/bash
echo "========================================"
echo "Executing $SCRIPT_NAME on node: \$(hostname)"
echo "Date: \$(date)"
echo "Node info: \$(uname -a)"
echo "========================================"
echo ""

# Create temp directory
TEMP_DIR=\$(mktemp -d)
cd "\$TEMP_DIR"

# Decode and save the script
echo "$SCRIPT_CONTENT" | base64 -d > "$SCRIPT_NAME"
chmod +x "$SCRIPT_NAME"

echo "Script uploaded to: \$TEMP_DIR/$SCRIPT_NAME"
echo ""

# Execute the script directly
sudo bash "$SCRIPT_NAME"

# Cleanup
cd /
rm -rf "\$TEMP_DIR"

echo ""
echo "========================================"
echo "Completed $SCRIPT_NAME on node: \$(hostname)"
echo "========================================"
EOF
)

echo "✓ Command prepared"

# Show what will be executed
echo ""
echo "Running '$SCRIPT_NAME' on:"
echo "  VMSS: $VMSS_NAME"
echo "  Instance: $INSTANCE_ID"
echo "  Resource Group: $NODE_RESOURCE_GROUP"
echo ""

# Create temporary file for the command
TEMP_COMMAND_FILE=$(mktemp)
echo "$REMOTE_COMMAND" > "$TEMP_COMMAND_FILE"

echo ""
echo "Executing command on node..."
echo "----------------------------------------"

# Run the command and capture the result
echo "Executing command on node..."
EXECUTION_RESULT=$(az vmss run-command invoke \
    --resource-group "$NODE_RESOURCE_GROUP" \
    --name "$VMSS_NAME" \
    --instance-id "$INSTANCE_ID" \
    --command-id RunShellScript \
    --scripts @"$TEMP_COMMAND_FILE" \
    --output json)

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ Successfully executed $SCRIPT_NAME on node"
    
    # Extract execution status and output
    STATUS=$(echo "$EXECUTION_RESULT" | jq -r '.value[0].code // "unknown"')
    DISPLAY_STATUS=$(echo "$EXECUTION_RESULT" | jq -r '.value[0].displayStatus // "unknown"')
    OUTPUT=$(echo "$EXECUTION_RESULT" | jq -r '.value[0].message // "no output"')
    
    echo "✓ Execution Status: $DISPLAY_STATUS"
    
    # Show the execution result
    echo ""
    echo "========================================"
    echo "SCRIPT OUTPUT"
    echo "========================================"
    echo "$OUTPUT"
    echo ""
    echo "========================================"
else
    echo ""
    echo "✗ Failed to execute $SCRIPT_NAME on node"
    RETURN_CODE=$?
fi

# Clean up
rm -f "$TEMP_COMMAND_FILE"

echo ""
echo "========================================"
echo "Execution Summary"
echo "========================================"
echo "Script: $SCRIPT_NAME"
echo "Target: $VMSS_NAME instance $INSTANCE_ID"
echo "Status: $([ ${RETURN_CODE:-0} -eq 0 ] && echo "SUCCESS" || echo "FAILED")"
echo ""
echo "Note: Azure VMSS run-command executes immediately and doesn't provide"
echo "persistent execution IDs for later querying. The output above shows"
echo "the complete execution result."
echo ""

exit ${RETURN_CODE:-0}