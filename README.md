# AKS ACR Integration with Secretless Authentication

This guide demonstrates how to configure Azure Kubernetes Service (AKS) to pull container images from Azure Container Registry (ACR) using **secretless authentication**. By leveraging workload identity and the Azure ACR credential provider, your Kubernetes workloads can securely access ACR without storing any credentials, passwords, or service principal secrets in your cluster.

## Prerequisites

- Azure CLI installed and configured
- kubectl installed
- An active Azure subscription

## Step 1: Create Resource Group and AKS Cluster

```bash
export RANDOM_ID="$(openssl rand -hex 3)"
export RESOURCE_GROUP="rg-aks-mirror-demo-$RANDOM_ID"
export LOCATION="southeastasia"
export CLUSTER_NAME="cluster-aks-mirror-demo-$RANDOM_ID"

# Create resource group
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

# Create AKS cluster with workload identity enabled
az aks create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --location "${LOCATION}" \
    --kubernetes-version 1.33 \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --node-vm-size "Standard_D2s_v5" \
    --generate-ssh-keys

# Get cluster credentials
az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --overwrite-existing
```

## Step 2: Retrieve the OIDC Issuer URL

```bash
export AKS_OIDC_ISSUER="$(az aks show --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "oidcIssuerProfile.issuerUrl" \
    --output tsv)"
```

## Step 3: Create a Managed Identity

```bash
export SUBSCRIPTION="$(az account show --query id --output tsv)"
export USER_ASSIGNED_IDENTITY_NAME="mi-aks-mirror-demo-$RANDOM_ID"

az identity create \
    --name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --subscription "${SUBSCRIPTION}"

export USER_ASSIGNED_CLIENT_ID="$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --query 'clientId' \
    --output tsv)"
```

## Step 4: Create Service Account and RBAC Configuration

```bash
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa$RANDOM_ID"
export TENANT_ID="$(az account show --query tenantId --output tsv)"

# Create service account with ACR annotations
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  annotations:
    kubernetes.azure.com/acr-client-id: "${USER_ASSIGNED_CLIENT_ID}"
    kubernetes.azure.com/acr-tenant-id: "${TENANT_ID}"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubelet-serviceaccount-reader
rules:
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubelet-serviceaccount-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubelet-serviceaccount-reader
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:nodes
EOF
```

## Step 5: Create the Federated Identity Credential

```bash
export FEDERATED_IDENTITY_CREDENTIAL_NAME="myFedIdentity$RANDOM_ID"

az identity federated-credential create \
    --name "${FEDERATED_IDENTITY_CREDENTIAL_NAME}" \
    --identity-name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --issuer "${AKS_OIDC_ISSUER}" \
    --subject system:serviceaccount:"${SERVICE_ACCOUNT_NAMESPACE}":"${SERVICE_ACCOUNT_NAME}" \
    --audience api://AzureADTokenExchange
```

## Step 6: Create an Azure Container Registry (ACR)

```bash
export ACR_NAME="acrmirror${RANDOM_ID}"

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


# Assign AcrPull role to the managed identity
# Use object ID (principalId) instead of client ID for role assignments
export USER_ASSIGNED_OBJECT_ID="$(az identity show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${USER_ASSIGNED_IDENTITY_NAME}" \
    --query 'principalId' \
    --output tsv)"
az role assignment create \
    --assignee-object-id "${USER_ASSIGNED_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role AcrPull \
    --scope "/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}"
```

## Step 7: Configure Credential Provider and Registry Mirror on AKS Nodes

```bash
# Apply the node configuration DaemonSet with ACR_NAME substitution
sed "s/{{ACR_NAME}}/${ACR_NAME}/g" k8s-templates/configure-nodes.yaml | kubectl apply -f -

# Wait for DaemonSet to complete configuration on all nodes
kubectl rollout status daemonset/configure-nodes -n kube-system --timeout=300s
```

**Inspect the deployment:**

You can use the troubleshooting scripts to check the configuration status on each node:

```bash
# Get node information and ready-to-use commands
./scripts/get-nodes.sh ${CLUSTER_NAME} ${RESOURCE_GROUP}
```

## Step 8: Deploy a Test Pod to Verify ACR Pull

```bash
# Deploy a test pod that pulls an image from ACR (via artifact cache)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-acr-pull
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
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

## Step 9: Test Registry Mirror with MCR Image

```bash
# Deploy a test pod that pulls directly from mcr.microsoft.com
# The registry mirror will transparently redirect to your ACR
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-mcr-mirror
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
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