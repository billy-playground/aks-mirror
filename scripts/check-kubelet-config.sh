#!/bin/bash

# Script to check kubelet credential provider configuration
# Usage: bash check-kubelet-config.sh

set -e

echo "=========================================="
echo "Kubelet Credential Provider Check"
echo "=========================================="

KUBELET_CONFIG_FILE="/etc/default/kubelet"

if [[ ! -f "${KUBELET_CONFIG_FILE}" ]]; then
    echo "✗ ERROR: ${KUBELET_CONFIG_FILE} not found!"
    exit 1
fi

# Expected values
EXPECTED_BIN_DIR="/opt"
EXPECTED_CONFIG_PATH="/etc/kubernetes/credential-provider/credential-provider-config.yaml"
EXPECTED_BINARY="${EXPECTED_BIN_DIR}/azure-acr-credential-provider"
EXPECTED_FEATURE_GATE="KubeletServiceAccountTokenForCredentialProviders=true"

# Extract actual values
ACTUAL_BIN_DIR=$(grep -oP -- '--image-credential-provider-bin-dir=\K[^ ]*' "${KUBELET_CONFIG_FILE}" 2>/dev/null || echo "")
ACTUAL_CONFIG_PATH=$(grep -oP -- '--image-credential-provider-config=\K[^ ]*' "${KUBELET_CONFIG_FILE}" 2>/dev/null || echo "")
FEATURE_GATES=$(grep -oP -- '--feature-gates=\K[^ ]*' "${KUBELET_CONFIG_FILE}" 2>/dev/null || echo "")

echo ""
echo "=== CHECK 1: Binary Directory ==="
if [[ "${ACTUAL_BIN_DIR}" == "${EXPECTED_BIN_DIR}" ]]; then
    echo "${EXPECTED_BIN_DIR} ✓"
else
    echo "${EXPECTED_BIN_DIR} ✗ (actual: ${ACTUAL_BIN_DIR:-NOT SET})"
fi

echo ""
echo "=== CHECK 2: Config Path ==="
if [[ "${ACTUAL_CONFIG_PATH}" == "${EXPECTED_CONFIG_PATH}" ]]; then
    echo "${EXPECTED_CONFIG_PATH} ✓"
else
    echo "${EXPECTED_CONFIG_PATH} ✗ (actual: ${ACTUAL_CONFIG_PATH:-NOT SET})"
fi

echo ""
echo "=== CHECK 3: Feature Gate ==="
if echo "${FEATURE_GATES}" | grep -q "KubeletServiceAccountTokenForCredentialProviders=true"; then
    echo "${EXPECTED_FEATURE_GATE} ✓"
else
    echo "${EXPECTED_FEATURE_GATE} ✗ (actual: ${FEATURE_GATES:-NOT SET})"
fi

echo ""
echo "=== CHECK 4: Binary File ==="
if [[ -x "${EXPECTED_BINARY}" ]]; then
    echo "${EXPECTED_BINARY} ✓"
else
    echo "${EXPECTED_BINARY} ✗ (not found or not executable)"
fi

echo ""
echo "=== CHECK 5: Config File ==="
if [[ -f "${EXPECTED_CONFIG_PATH}" ]]; then
    echo "${EXPECTED_CONFIG_PATH} ✓"
    echo ""
    cat "${EXPECTED_CONFIG_PATH}"
else
    echo "${EXPECTED_CONFIG_PATH} ✗ (not found)"
fi

echo ""
echo "=== CHECK 6: Kubelet Service ==="
if systemctl is-active --quiet kubelet; then
    echo "Running ✓"
else
    echo "Not running ✗"
    journalctl -u kubelet -n 10 --no-pager
fi
