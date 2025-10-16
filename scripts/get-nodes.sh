#!/bin/bash

# Script to get AKS node information for manual VMSS commands
# Usage: bash get-nodes.sh <CLUSTER_NAME> <RESOURCE_GROUP>

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <CLUSTER_NAME> <RESOURCE_GROUP>"
    echo ""
    echo "This script will output the VMSS names and instance IDs"
    echo "that you can use with 'az vmss run-command invoke'"
    exit 1
fi

CLUSTER_NAME="$1"
RESOURCE_GROUP="$2"

echo "========================================"
echo "AKS Node Information"
echo "========================================"
echo "Cluster: $CLUSTER_NAME"
echo "Resource Group: $RESOURCE_GROUP"
echo ""

# Check if Azure CLI is logged in
if ! az account show &>/dev/null; then
    echo "Error: Not logged into Azure CLI. Run 'az login' first."
    exit 1
fi

echo "Getting cluster information..."

# Get node resource group
NODE_RESOURCE_GROUP=$(az aks show -n "$CLUSTER_NAME" -g "$RESOURCE_GROUP" --query 'nodeResourceGroup' -o tsv)

if [ -z "$NODE_RESOURCE_GROUP" ]; then
    echo "Error: Could not find node resource group for cluster $CLUSTER_NAME"
    exit 1
fi

echo "✓ Node Resource Group: $NODE_RESOURCE_GROUP"
echo ""

# Get all VMSS in the node resource group
echo "Finding VMSS instances..."
VMSS_LIST=$(az vmss list -g "$NODE_RESOURCE_GROUP" --query '[].name' -o tsv)

if [ -z "$VMSS_LIST" ]; then
    echo "Error: No VMSS found in resource group $NODE_RESOURCE_GROUP"
    exit 1
fi

echo ""
echo "========================================"
echo "VMSS and Instance Information"
echo "========================================"

# Counter for manual commands
COUNTER=1

# Get instances from each VMSS
for vmss_name in $VMSS_LIST; do
    echo ""
    echo "VMSS: $vmss_name"
    echo "----------------------------------------"
    
    INSTANCES=$(az vmss list-instances -n "$vmss_name" -g "$NODE_RESOURCE_GROUP" --query '[].{id:instanceId, name:name, powerState:powerState}' -o json)
    
    # Parse instances
    INSTANCE_COUNT=$(echo "$INSTANCES" | jq length)
    
    if [ $INSTANCE_COUNT -eq 0 ]; then
        echo "  No instances found"
        continue
    fi
    
    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        INSTANCE_ID=$(echo "$INSTANCES" | jq -r ".[$i].id")
        INSTANCE_NAME=$(echo "$INSTANCES" | jq -r ".[$i].name")
        POWER_STATE=$(echo "$INSTANCES" | jq -r ".[$i].powerState // \"unknown\"")
        
        echo "  Instance $COUNTER:"
        echo "    Name: $INSTANCE_NAME"
        echo "    ID: $INSTANCE_ID"
        echo "    Power State: $POWER_STATE"
        echo ""
        
        COUNTER=$((COUNTER + 1))
    done
done

echo ""
echo "========================================"
echo "Manual Command Examples"
echo "========================================"
echo ""
echo "To run a command on a specific node, use:"
echo ""
echo "az vmss run-command invoke \\"
echo "  --resource-group '$NODE_RESOURCE_GROUP' \\"
echo "  --name '<VMSS_NAME>' \\"
echo "  --instance-id '<INSTANCE_ID>' \\"
echo "  --command-id RunShellScript \\"
echo "  --scripts 'sudo bash -c \"<YOUR_COMMAND>\"'"
echo ""
echo "Examples:"
echo ""

# Generate example commands for each instance
COUNTER=1
for vmss_name in $VMSS_LIST; do
    INSTANCES=$(az vmss list-instances -n "$vmss_name" -g "$NODE_RESOURCE_GROUP" --query '[].{id:instanceId, name:name}' -o json)
    INSTANCE_COUNT=$(echo "$INSTANCES" | jq length)
    
    for i in $(seq 0 $((INSTANCE_COUNT - 1))); do
        INSTANCE_ID=$(echo "$INSTANCES" | jq -r ".[$i].id")
        INSTANCE_NAME=$(echo "$INSTANCES" | jq -r ".[$i].name")
        
        echo "# Node $COUNTER ($INSTANCE_NAME):"
        echo "az vmss run-command invoke \\"
        echo "  --resource-group '$NODE_RESOURCE_GROUP' \\"
        echo "  --name '$vmss_name' \\"
        echo "  --instance-id '$INSTANCE_ID' \\"
        echo "  --command-id RunShellScript \\"
        echo "  --scripts 'sudo crictl ps | grep setup-credential-provider'"
        echo ""
        
        COUNTER=$((COUNTER + 1))
    done
done

echo "========================================"
echo "Quick Commands for Troubleshooting"
echo "========================================"

# Get first VMSS name and first instance as default
FIRST_VMSS=$(echo "$VMSS_LIST" | head -1)
FIRST_VMSS_INSTANCES=$(az vmss list-instances -n "$FIRST_VMSS" -g "$NODE_RESOURCE_GROUP" --query '[].instanceId' -o tsv)
DEFAULT_INSTANCE=$(echo "$FIRST_VMSS_INSTANCES" | head -1)

echo ""
echo "Using first VMSS ($FIRST_VMSS) and first instance ($DEFAULT_INSTANCE) for ready-to-use commands:"
echo ""
echo "# Check kubelet configuration on specific node:"
echo "bash scripts/run-script-on-node.sh $CLUSTER_NAME $RESOURCE_GROUP $FIRST_VMSS $DEFAULT_INSTANCE check-kubelet-config.sh"
echo ""
echo "# Detailed troubleshooting on specific node:"
echo "bash scripts/run-script-on-node.sh $CLUSTER_NAME $RESOURCE_GROUP $FIRST_VMSS $DEFAULT_INSTANCE troubleshoot-configure-node.sh"
echo ""
echo "# Manual setup test on specific node:"
echo "bash scripts/run-script-on-node.sh $CLUSTER_NAME $RESOURCE_GROUP $FIRST_VMSS $DEFAULT_INSTANCE manual-setup.sh"
echo ""
echo "# Run on all nodes:"
echo "bash scripts/run-on-nodes.sh $CLUSTER_NAME $RESOURCE_GROUP"