#!/bin/bash

# Manual setup script for testing credential provider configuration
# This script replicates what the DaemonSet does but with more control
# Usage: sudo bash manual-setup.sh

set -e

echo "========================================"
echo "Manual Credential Provider Setup"
echo "========================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: ${ARCH}"

if [[ "${ARCH}" == "x86_64" ]]; then
    BINARY_ARCH="amd64"
elif [[ "${ARCH}" == "aarch64" ]]; then
    BINARY_ARCH="arm64"
else
    echo "ERROR: Unsupported architecture: ${ARCH}"
    exit 1
fi

echo ""
echo "Step 1: Creating directories..."
mkdir -p /etc/kubernetes/credential-provider
mkdir -p /opt
echo "✓ Created directories"

echo ""
echo "Step 2: Downloading binary..."
curl -L "https://raw.githubusercontent.com/billy-playground/aks-mirror/refs/heads/master/bin/${BINARY_ARCH}/azure-acr-credential-provider" \
    -o /opt/azure-acr-credential-provider
chmod +x /opt/azure-acr-credential-provider
echo "✓ Downloaded and made executable: /opt/azure-acr-credential-provider"

echo ""
echo "Step 3: Creating configuration..."
CRED_CONFIG_FILE="/etc/kubernetes/credential-provider/credential-provider-config.yaml"

cat > "${CRED_CONFIG_FILE}" << 'EOF'
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
EOF

echo "✓ Created configuration file"
echo "Configuration content:"
cat "${CRED_CONFIG_FILE}" | sed 's/^/  /'

echo ""
echo "Step 4: Backing up kubelet configuration..."
KUBELET_CONFIG_FILE="/etc/default/kubelet"

if [ ! -f "${KUBELET_CONFIG_FILE}.bak" ]; then
    cp "${KUBELET_CONFIG_FILE}" "${KUBELET_CONFIG_FILE}.bak"
    echo "✓ Created backup: ${KUBELET_CONFIG_FILE}.bak"
else
    echo "✓ Backup already exists: ${KUBELET_CONFIG_FILE}.bak"
fi

echo ""
echo "Step 5: Updating kubelet configuration..."
echo "Original kubelet config:"
cat "${KUBELET_CONFIG_FILE}" | sed 's/^/  /'

# Create temporary file for modifications
TEMP_FILE=$(mktemp)
cp "${KUBELET_CONFIG_FILE}" "${TEMP_FILE}"

# Apply modifications
sed -i 's|--image-credential-provider-bin-dir=[^ ]*|--image-credential-provider-bin-dir=/opt|g' "${TEMP_FILE}"
sed -i 's|--image-credential-provider-config=[^ ]*|--image-credential-provider-config=/etc/kubernetes/credential-provider/credential-provider-config.yaml|g' "${TEMP_FILE}"

# Add feature gate if not present
if ! grep -q "KubeletServiceAccountTokenForCredentialProviders=true" "${TEMP_FILE}"; then
    if grep -q -- "--feature-gates=" "${TEMP_FILE}"; then
        sed -i 's|--feature-gates=|--feature-gates=KubeletServiceAccountTokenForCredentialProviders=true,|g' "${TEMP_FILE}"
    else
        sed -i 's|\(KUBELET_FLAGS=.*\)|\1 --feature-gates=KubeletServiceAccountTokenForCredentialProviders=true|' "${TEMP_FILE}"
    fi
fi

echo ""
echo "Modified kubelet config:"
cat "${TEMP_FILE}" | sed 's/^/  /'

echo ""
echo "Configuration diff:"
diff "${KUBELET_CONFIG_FILE}" "${TEMP_FILE}" || true

echo ""
echo "Step 6: Validation checks..."

# Validation
VALID=true

if grep -q "image-credential-provider-config=/etc/kubernetes/credential-provider/credential-provider-config.yaml" "${TEMP_FILE}"; then
    echo "✓ Credential provider config path: FOUND"
else
    echo "✗ Credential provider config path: MISSING"
    VALID=false
fi

if grep -q "image-credential-provider-bin-dir=/opt" "${TEMP_FILE}"; then
    echo "✓ Credential provider bin dir: FOUND"
else
    echo "✗ Credential provider bin dir: MISSING"
    VALID=false
fi

if grep -q "KubeletServiceAccountTokenForCredentialProviders=true" "${TEMP_FILE}"; then
    echo "✓ Feature gate: FOUND"
else
    echo "✗ Feature gate: MISSING"
    VALID=false
fi

if [ "$VALID" = false ]; then
    echo ""
    echo "✗ Validation failed! Configuration not applied."
    rm "${TEMP_FILE}"
    exit 1
fi

echo ""
echo "Step 7: Applying configuration..."
cp "${TEMP_FILE}" "${KUBELET_CONFIG_FILE}"
rm "${TEMP_FILE}"
echo "✓ Configuration applied"

echo ""
echo "Step 8: Cleaning up kubelet journal and restarting..."

# Force cleanup kubelet journal
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true

systemctl restart kubelet

# echo "Waiting 10 seconds for kubelet to start..."
# sleep 10

# # if systemctl is-active --quiet kubelet; then
#     echo "✓ Kubelet restarted successfully"
    
#     # Mark as configured
#     touch /opt/credential-provider-configured
#     echo "✓ Created sentinel file"
    
#     echo ""
#     echo "========================================"
#     echo "✓ Setup completed successfully!"
#     echo "========================================"
    
#     echo ""
#     echo "Kubelet status:"
#     systemctl status kubelet --no-pager -l | head -20
    
# else
#     echo "✗ Kubelet failed to restart!"
#     echo ""
#     echo "Restoring backup configuration..."
#     cp "${KUBELET_CONFIG_FILE}.bak" "${KUBELET_CONFIG_FILE}"
#     systemctl restart kubelet
    
#     echo ""
#     echo "Kubelet logs:"
#     journalctl -u kubelet --no-pager -l --since="1 minute ago" | tail -20
    
#     echo ""
#     echo "✗ Setup failed - configuration restored"
#     exit 1
# fi