# AKS ACR Integration with Secretless Authentication Using Identity Bindings

This guide demonstrates how to configure Azure Kubernetes Service (AKS) to pull container images from Azure Container Registry (ACR) using **secretless authentication** with **Identity Bindings**. By leveraging identity bindings and the Azure ACR credential provider, your Kubernetes workloads can securely access ACR without storing any credentials, passwords, or service principal secrets in your cluster.

**What are Identity Bindings?**

Identity Bindings is a preview feature in AKS that simplifies workload identity configuration by:

- Automatically creating federated credentials between your service accounts and Azure managed identities
- Eliminating manual federated credential creation steps
- Providing a streamlined OIDC issuer configuration
- Simplifying the authentication flow for both pods and kubelet credential providers

## Prerequisites

- Azure CLI installed and configured
- kubectl installed
- An active Azure subscription
- AKS preview extension: `az extension add --name aks-preview`
- Register the identity binding preview feature:

  ```bash
  az feature register \
    --namespace Microsoft.ContainerService \
    --name IdentityBindingPreview
  
  # Wait for registration to complete (this may take several minutes)
  az feature show \
    --namespace Microsoft.ContainerService \
    --name IdentityBindingPreview \
    --query properties.state -o tsv
  
  # Once registered, refresh the provider
  az provider register --namespace Microsoft.ContainerService
  ```

## Step 1: Create Resource Group, AKS Cluster, Managed Identity, and ACR

```bash
export RANDOM_ID="$(openssl rand -hex 3)"
export RESOURCE_GROUP="rg-aks-mirror-demo-$RANDOM_ID"
export LOCATION="southeastasia"
export CLUSTER_NAME="cluster-aks-mirror-demo-$RANDOM_ID"
export SUBSCRIPTION="$(az account show --query id --output tsv)"
export ACR_NAME="acrmirror${RANDOM_ID}"

# Create resource group
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

# Create AKS cluster with workload identity enabled
az aks create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --location "${LOCATION}" \
    --kubernetes-version 1.34 \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --node-vm-size "Standard_D2s_v5" \
    --generate-ssh-keys

# Get cluster credentials
az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --overwrite-existing

# Get the kubelet identity from the cluster
export KUBELET_IDENTITY_CLIENT_ID="$(az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --query 'identityProfile.kubeletidentity.clientId' \
    --output tsv)"

export KUBELET_IDENTITY_OBJECT_ID="$(az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --query 'identityProfile.kubeletidentity.objectId' \
    --output tsv)"

export KUBELET_IDENTITY_RESOURCE_ID="$(az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --query 'identityProfile.kubeletidentity.resourceId' \
    --output tsv)"

# Create Azure Container Registry
az acr create \
    --name "${ACR_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --sku Premium

# Enable artifact cache for all repositories from mcr.microsoft.com
az acr cache create \
    --registry "${ACR_NAME}" \
    --name mcr-microsoft-cache \
    --source-repo "mcr.microsoft.com/*" \
    --target-repo "*"

# Assign AcrPull role to the kubelet identity
az role assignment create \
    --assignee-object-id "${KUBELET_IDENTITY_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role AcrPull \
    --scope "/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}"
```

## Step 2: Configure Identity Binding and Service Account

```bash
# Create identity binding for kubelet identity (replaces manual federated credential creation)
# Note: identity binding name must be lowercase letters, numbers, and hyphens only
az aks identity-binding create \
    --resource-group "${RESOURCE_GROUP}" \
    --cluster-name "${CLUSTER_NAME}" \
    --name "kubelet-identity-binding-$RANDOM_ID" \
    --managed-identity-resource-id "${KUBELET_IDENTITY_RESOURCE_ID}"

# Set up service account variables
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa$RANDOM_ID"
export TENANT_ID="$(az account show --query tenantId --output tsv)"

# Create Service Account with workload identity annotation. TODO: move to overlaymgr
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: request-sa-token-audience
rules:
- verbs: ["request-serviceaccounts-token-audience"]
  apiGroups: [""]
  resources: ["api://AKSIdentityBinding"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubelet-node-permissions
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: request-sa-token-audience
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:nodes
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: use-ki-${KUBELET_IDENTITY_CLIENT_ID}
rules:
- verbs: ["use-managed-identity"]
  apiGroups: ["cid.wi.aks.azure.com"]
  resources: ["${KUBELET_IDENTITY_CLIENT_ID}"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: use-ki-${KUBELET_IDENTITY_CLIENT_ID}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: use-ki-${KUBELET_IDENTITY_CLIENT_ID}
subjects:
- kind: Group
  name: system:serviceaccounts
  apiGroup: rbac.authorization.k8s.io
EOF
```

## Step 3: Deploy Test Pod and Configure Credential Provider on AKS Nodes

```bash
# Deploy a test pod to obtain SNI configuration
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-shell
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
  annotations:
    azure.workload.identity/use-identity-binding: "true"
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
  - name: azure-cli
    image: mcr.microsoft.com/azure-cli:cbl-mariner2.0
    command: ["bash", "-c", "sleep infinity"]
  restartPolicy: Never
EOF

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/test-shell -n ${SERVICE_ACCOUNT_NAMESPACE} --timeout=120s

# Auto-detect SNI configuration from the test pod
echo "Auto-detecting test configuration..."
SNI_NAME=$(kubectl get pod test-shell -n ${SERVICE_ACCOUNT_NAMESPACE} -o jsonpath='{.spec.containers[0].env[?(@.name=="AZURE_KUBERNETES_SNI_NAME")].value}' 2>/dev/null || echo "")

if [[ -z "${SNI_NAME}" ]]; then
  echo "ERROR: Could not detect SNI_NAME from test pod"
  echo "Please ensure the pod has workload identity annotations and is running"
  return 1
fi

echo "Detected SNI_NAME: ${SNI_NAME}"

# Apply the node configuration DaemonSet with ACR_NAME, SNI_NAME, and DEFAULT_CLIENT_ID substitution
sed -e "s/{{ACR_NAME}}/${ACR_NAME}/g" -e "s/{{SNI_NAME}}/${SNI_NAME}/g" -e "s/{{DEFAULT_CLIENT_ID}}/${KUBELET_IDENTITY_CLIENT_ID}/g" k8s-templates/configure-nodes.yaml | kubectl apply -f -

# Wait for DaemonSet to complete configuration on all nodes
kubectl rollout status daemonset/configure-nodes -n kube-system --timeout=300s
```

**Inspect the deployment:**

You can use the troubleshooting scripts to check the configuration status on each node:

```bash
# Get node information and ready-to-use commands
./scripts/get-nodes.sh ${CLUSTER_NAME} ${RESOURCE_GROUP}
```

## Step 4: Verify ACR Pull with Additional Test Pod

```bash
# Deploy another test pod that pulls an image from ACR (via artifact cache)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-acr-pull
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
  - name: hello-world
    image: ${ACR_NAME}.azurecr.io/mcr/hello-world:latest
  restartPolicy: Never
EOF

# Watch the pod status
kubectl get pod test-acr-pull -n ${SERVICE_ACCOUNT_NAMESPACE} --watch
```

If the pod reaches "Completed" status, your ACR credential provider setup is working correctly!

## Step 5: Test Registry Mirror with MCR Image

```bash
# Deploy a test pod that pulls directly from mcr.microsoft.com
# The registry mirror will transparently redirect to your ACR
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-mcr-mirror
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
  - name: hello-world
    image: mcr.microsoft.com/dotnet/samples:latest
  restartPolicy: Never
EOF

# Watch the pod status
kubectl get pod test-mcr-mirror -n ${SERVICE_ACCOUNT_NAMESPACE} --watch
```

If the pod reaches "Completed" status, your registry mirror is working correctly and MCR images are being served through your ACR!

## Cleanup

To remove all resources created in this demo:

```bash
az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
```
