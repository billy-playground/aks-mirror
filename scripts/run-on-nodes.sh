#!/bin/bash

# Script to run troubleshooting commands on AKS VMSS nodes
# Usage: bash run-on-nodes.sh <CLUSTER_NAME> <RESOURCE_GROUP> <LOCATION> [COMMAND_SCRIPT]

set -e

# Check if required parameters are provided
if [ $# -lt 3 ]; then
    echo "Usage: $0 <CLUSTER_NAME> <RESOURCE_GROUP> <LOCATION> [COMMAND_SCRIPT]"
    echo ""
    echo "Parameters:"
    echo "  CLUSTER_NAME   - Name of the AKS cluster"
    echo "  RESOURCE_GROUP - Resource group containing the cluster"
    echo "  LOCATION       - Azure region where cluster is located"
    echo "  COMMAND_SCRIPT - Optional: specific script to run (default: quick-check.sh)"
    echo ""
    echo "Examples:"
    echo "  $0 my-cluster my-rg eastus"
    echo "  $0 my-cluster my-rg eastus troubleshoot-configure-node.sh"
    echo "  $0 my-cluster my-rg eastus manual-setup.sh"
    exit 1
fi

CLUSTER_NAME="$1"
RESOURCE_GROUP="$2"
LOCATION="$3"
COMMAND_SCRIPT="${4:-quick-check.sh}"

echo "========================================"
echo "AKS Node Troubleshooting Runner"
echo "========================================"
echo "Cluster: $CLUSTER_NAME"
echo "Resource Group: $RESOURCE_GROUP"
echo "Location: $LOCATION"
echo "Script to run: $COMMAND_SCRIPT"
echo ""

# Check if Azure CLI is logged in
if ! az account show &>/dev/null; then
    echo "Error: Not logged into Azure CLI. Run 'az login' first."
    exit 1
fi

echo "Step 1: Getting AKS cluster information..."

# Get cluster info
CLUSTER_INFO=$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query '{nodeResourceGroup:nodeResourceGroup, fqdn:fqdn}' -o json)
NODE_RESOURCE_GROUP=$(echo "$CLUSTER_INFO" | jq -r '.nodeResourceGroup')
CLUSTER_FQDN=$(echo "$CLUSTER_INFO" | jq -r '.fqdn')

echo "✓ Cluster FQDN: $CLUSTER_FQDN"
echo "✓ Node Resource Group: $NODE_RESOURCE_GROUP"

echo ""
echo "Step 2: Finding VMSS instances..."

# Get all VMSS in the node resource group
VMSS_LIST=$(az vmss list -g "$NODE_RESOURCE_GROUP" --query '[].name' -o tsv)

if [ -z "$VMSS_LIST" ]; then
    echo "Error: No VMSS found in resource group $NODE_RESOURCE_GROUP"
    exit 1
fi

echo "Found VMSS:"
for vmss in $VMSS_LIST; do
    echo "  - $vmss"
done

echo ""
echo "Step 3: Getting VMSS instance details..."

# Create arrays to store instance information
declare -a VMSS_NAMES
declare -a INSTANCE_IDS
declare -a INSTANCE_NAMES

# Get instances from each VMSS
for vmss_name in $VMSS_LIST; do
    echo "Getting instances for VMSS: $vmss_name"
    
    INSTANCES=$(az vmss list-instances -n "$vmss_name" -g "$NODE_RESOURCE_GROUP" --query '[].{id:instanceId, name:name}' -o json)
    
    # Parse instances
    INSTANCE_COUNT=$(echo "$INSTANCES" | jq length)
    
    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        INSTANCE_ID=$(echo "$INSTANCES" | jq -r ".[$i].id")
        INSTANCE_NAME=$(echo "$INSTANCES" | jq -r ".[$i].name")
        
        VMSS_NAMES+=("$vmss_name")
        INSTANCE_IDS+=("$INSTANCE_ID")
        INSTANCE_NAMES+=("$INSTANCE_NAME")
        
        echo "  ✓ Instance: $INSTANCE_NAME (ID: $INSTANCE_ID)"
    done
done

TOTAL_INSTANCES=${#INSTANCE_IDS[@]}
echo ""
echo "Found $TOTAL_INSTANCES total instances"

if [ $TOTAL_INSTANCES -eq 0 ]; then
    echo "Error: No VMSS instances found"
    exit 1
fi

echo ""
echo "Step 4: Preparing command script..."

# Check if the script file exists locally
SCRIPT_PATH="$(dirname "$0")/$COMMAND_SCRIPT"
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "Error: Script file not found: $SCRIPT_PATH"
    echo "Available scripts:"
    ls -la "$(dirname "$0")"/*.sh 2>/dev/null || echo "No .sh files found in $(dirname "$0")"
    exit 1
fi

echo "✓ Using script: $SCRIPT_PATH"

# Read the script content
SCRIPT_CONTENT=$(base64 -w 0 "$SCRIPT_PATH")

# Create the command to run on each node
RUN_COMMAND=$(cat << 'EOF'
#!/bin/bash
echo "========================================"
echo "Running on node: $(hostname)"
echo "Date: $(date)"
echo "========================================"

# Decode and save the script
echo "$SCRIPT_CONTENT" | base64 -d > /tmp/remote-script.sh
chmod +x /tmp/remote-script.sh

# Run the script
cd /tmp
sudo bash /tmp/remote-script.sh

echo ""
echo "========================================"
echo "Completed on node: $(hostname)"
echo "========================================"
EOF
)

# Replace the placeholder with actual script content
RUN_COMMAND=$(echo "$RUN_COMMAND" | sed "s/\$SCRIPT_CONTENT/$SCRIPT_CONTENT/")

echo ""
echo "Step 5: Running commands on all nodes..."

# Function to run command on a single node
run_on_node() {
    local vmss_name="$1"
    local instance_id="$2"
    local instance_name="$3"
    local node_index="$4"
    
    echo ""
    echo "----------------------------------------"
    echo "[$node_index/$TOTAL_INSTANCES] Running on: $instance_name"
    echo "VMSS: $vmss_name, Instance ID: $instance_id"
    echo "----------------------------------------"
    
    # Create a temporary file for the command
    local temp_command_file=$(mktemp)
    echo "$RUN_COMMAND" > "$temp_command_file"
    
    # Run the command and capture execution ID
    local execution_result=$(az vmss run-command invoke \
        --resource-group "$NODE_RESOURCE_GROUP" \
        --name "$vmss_name" \
        --instance-id "$instance_id" \
        --command-id RunShellScript \
        --scripts @"$temp_command_file" \
        --output json)
    
    if [ $? -eq 0 ]; then
        local execution_id=$(echo "$execution_result" | jq -r '.name // .id // "unknown"')
        echo "✓ Successfully completed on $instance_name"
        echo "  Execution ID: $execution_id"
    else
        echo "✗ Failed on $instance_name"
    fi
    
    # Clean up temp file
    rm -f "$temp_command_file"
    
    echo "----------------------------------------"
}

# Prompt for confirmation
echo ""
echo "About to run '$COMMAND_SCRIPT' on $TOTAL_INSTANCES nodes:"
for i in "${!INSTANCE_NAMES[@]}"; do
    echo "  - ${INSTANCE_NAMES[$i]}"
done

echo ""
read -p "Continue? (y/N): " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Run on all nodes
for i in "${!VMSS_NAMES[@]}"; do
    run_on_node "${VMSS_NAMES[$i]}" "${INSTANCE_IDS[$i]}" "${INSTANCE_NAMES[$i]}" "$((i + 1))"
done

echo ""
echo "========================================"
echo "✓ Completed running '$COMMAND_SCRIPT' on all $TOTAL_INSTANCES nodes"
echo "========================================"
echo ""
echo "Summary:"
echo "- Cluster: $CLUSTER_NAME"
echo "- Resource Group: $RESOURCE_GROUP"
echo "- Node Resource Group: $NODE_RESOURCE_GROUP"
echo "- Script executed: $COMMAND_SCRIPT"
echo "- Total nodes: $TOTAL_INSTANCES"
echo ""
echo "Note: Check the output above for any failed executions."