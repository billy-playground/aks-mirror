#!/bin/bash

# Troubleshooting script for configure-node DaemonSet issues
# Run this on AKS VMSS nodes to diagnose credential provider setup problems
# Usage: sudo bash troubleshoot-configure-node.sh

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "========================================"
echo "Configure Node Troubleshooting Script"
echo "Started at: $TIMESTAMP"
echo "Node: $(hostname)"
echo "========================================"

# 1. Check Container Status
echo ""
echo "########## 1. CONTAINER STATUS ##########"
echo ""

CONTAINER_ID=$(crictl ps 2>/dev/null | grep setup-credential-provider | awk '{print $1}' | head -1)

if [ -n "$CONTAINER_ID" ]; then
    echo "✓ Container running: $CONTAINER_ID"
    echo ""
    echo "Container logs (last 30 lines):"
    crictl logs --tail=30 "$CONTAINER_ID" 2>/dev/null || echo "Failed to get container logs"
else
    echo "✗ No setup-credential-provider container running"
fi

# 2. Check Key Files
echo ""
echo "########## 2. KEY FILES ##########"
echo ""

if [ -f "/opt/azure-acr-credential-provider" ]; then
    echo "✓ Binary exists: /opt/azure-acr-credential-provider"
else
    echo "✗ Binary missing: /opt/azure-acr-credential-provider"
fi

if [ -f "/etc/kubernetes/credential-provider/credential-provider-config.yaml" ]; then
    echo "✓ Config exists"
    echo ""
    echo "Config content:"
    cat /etc/kubernetes/credential-provider/credential-provider-config.yaml
else
    echo "✗ Config missing: /etc/kubernetes/credential-provider/credential-provider-config.yaml"
fi

if [ -f "/opt/credential-provider-configured" ]; then
    echo "✓ Sentinel file exists"
else
    echo "✗ Sentinel file missing"
fi

# 3. Check Kubelet Configuration
echo ""
echo "########## 3. KUBELET CONFIGURATION ##########"
echo ""

if [ -f "/etc/default/kubelet" ]; then
    echo "Kubelet config:"
    cat /etc/default/kubelet
    echo ""
    
    if grep -q "image-credential-provider" /etc/default/kubelet; then
        echo "✓ Kubelet configured with credential provider"
    else
        echo "✗ Kubelet not configured with credential provider"
    fi
else
    echo "✗ Kubelet config file not found"
fi

# 4. Check Kubelet Service Status (MAIN FOCUS)
echo ""
echo "########## 4. KUBELET STATUS ##########"
echo ""

if systemctl is-active kubelet >/dev/null 2>&1; then
    echo "✓ Kubelet is running"
else
    echo "✗ Kubelet is NOT running"
fi

echo ""
echo "Kubelet service status:"
systemctl status kubelet --no-pager -l 2>&1 | head -20

echo ""
echo "========================================"
echo "KUBELET LOGS"
echo "========================================"
journalctl -xeu kubelet --no-pager 2>&1

# Summary
echo ""
echo "========================================"
echo "TROUBLESHOOTING SUMMARY"
echo "========================================"
echo "Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""