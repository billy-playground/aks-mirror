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
echo "Expected: ${EXPECTED_BIN_DIR}"
if [[ "${ACTUAL_BIN_DIR}" == "${EXPECTED_BIN_DIR}" ]]; then
    echo "Actual:   ${ACTUAL_BIN_DIR} ✓"
else
    echo "Actual:   ${ACTUAL_BIN_DIR:-NOT SET} ✗"
fi

echo ""
echo "=== CHECK 2: Config Path ==="
echo "Expected: ${EXPECTED_CONFIG_PATH}"
if [[ "${ACTUAL_CONFIG_PATH}" == "${EXPECTED_CONFIG_PATH}" ]]; then
    echo "Actual:   ${ACTUAL_CONFIG_PATH} ✓"
else
    echo "Actual:   ${ACTUAL_CONFIG_PATH:-NOT SET} ✗"
fi

echo ""
echo "=== CHECK 3: Feature Gate ==="
echo "Expected: ${EXPECTED_FEATURE_GATE}"
if echo "${FEATURE_GATES}" | grep -q "KubeletServiceAccountTokenForCredentialProviders=true"; then
    echo "Actual:   Found in: ${FEATURE_GATES} ✓"
else
    echo "Actual:   ${FEATURE_GATES:-NOT SET} ✗"
fi

echo ""
echo "=== CHECK 4: Binary File ==="
echo "Expected: ${EXPECTED_BINARY} (executable)"
if [[ -x "${EXPECTED_BINARY}" ]]; then
    echo "Actual:   $(ls -lh "${EXPECTED_BINARY}" | awk '{print $9, $5, $1}') ✓"
else
    echo "Actual:   ${EXPECTED_BINARY} not found or not executable ✗"
fi

echo ""
echo "=== CHECK 5: Config File ==="
echo "Expected: ${EXPECTED_CONFIG_PATH} (valid YAML)"
if [[ -f "${EXPECTED_CONFIG_PATH}" ]]; then
    echo "Actual:   File exists ✓"
    echo ""
    echo "Content:"
    cat "${EXPECTED_CONFIG_PATH}"
else
    echo "Actual:   ${EXPECTED_CONFIG_PATH} not found ✗"
fi

echo ""
echo "=== CHECK 6: Kubelet Service ==="
if systemctl is-active --quiet kubelet; then
    echo "Status:   Running ✓"
else
    echo "Status:   Not running ✗"
    echo ""
    echo "Last 10 log lines:"
    journalctl -u kubelet -n 10 --no-pager
fi

echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="

CHECKS_PASSED=0
CHECKS_TOTAL=6

[[ "${ACTUAL_BIN_DIR}" == "${EXPECTED_BIN_DIR}" ]] && ((CHECKS_PASSED++))
[[ "${ACTUAL_CONFIG_PATH}" == "${EXPECTED_CONFIG_PATH}" ]] && ((CHECKS_PASSED++))
echo "${FEATURE_GATES}" | grep -q "KubeletServiceAccountTokenForCredentialProviders=true" && ((CHECKS_PASSED++))
[[ -x "${EXPECTED_BINARY}" ]] && ((CHECKS_PASSED++))
[[ -f "${EXPECTED_CONFIG_PATH}" ]] && ((CHECKS_PASSED++))
systemctl is-active --quiet kubelet && ((CHECKS_PASSED++))

echo "Checks passed: ${CHECKS_PASSED}/${CHECKS_TOTAL}"

if [[ ${CHECKS_PASSED} -eq ${CHECKS_TOTAL} ]]; then
    echo "Result: ALL CHECKS PASSED ✓"
else
    echo "Result: SOME CHECKS FAILED ✗"
fi
echo "=========================================="
