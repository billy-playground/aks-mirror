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
    --kubernetes-version 1.33 \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --node-vm-size "Standard_D2s_v5" \
    --generate-ssh-keys

# Get cluster credentials
az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --overwrite-existing

# Create a new user-managed identity for ACR access
export IDENTITY_NAME="id-acr-access-${RANDOM_ID}"

az identity create \
    --name "${IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --location "${LOCATION}"

# Get the identity details
export USER_IDENTITY_CLIENT_ID="$(az identity show \
    --name "${IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query 'clientId' \
    --output tsv)"

export USER_IDENTITY_OBJECT_ID="$(az identity show \
    --name "${IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query 'principalId' \
    --output tsv)"

export USER_IDENTITY_RESOURCE_ID="$(az identity show \
    --name "${IDENTITY_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query 'id' \
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

# Assign AcrPull role to the user-managed identity
az role assignment create \
    --assignee-object-id "${USER_IDENTITY_OBJECT_ID}" \
    --assignee-principal-type ServicePrincipal \
    --role AcrPull \
    --scope "/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerRegistry/registries/${ACR_NAME}"
```

## Step 2: Install Identity Mapping CRD and Configure Service Accounts

```bash
# Install the Identity Mapping CRD
kubectl apply -f k8s-templates/identity-mapping-crd.yaml

# Deploy the Identity Mapping Controller
kubectl apply -f k8s-templates/identity-mapping-controller.yaml

# Wait for controller to be ready
kubectl wait --for=condition=Available deployment/identity-mapping-controller -n kube-system --timeout=120s

# Create identity binding for the user-managed identity (replaces manual federated credential creation)
# Note: identity binding name must be lowercase letters, numbers, and hyphens only
az aks identity-binding create \
    --resource-group "${RESOURCE_GROUP}" \
    --cluster-name "${CLUSTER_NAME}" \
    --name "acr-identity-binding-$RANDOM_ID" \
    --managed-identity-resource-id "${USER_IDENTITY_RESOURCE_ID}"

# Set up service account variables
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa$RANDOM_ID"
export TENANT_ID="$(az account show --query tenantId --output tsv)"

# Create Service Account with workload identity annotation
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
EOF

# Create the IdentityMapping resource to map the service account to the user-managed identity
cat <<EOF | kubectl apply -f -
apiVersion: aks.azure.com/v1alpha1
kind: IdentityMapping
metadata:
  name: default-identity-mappings
spec:
  bindings:
    "${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}": "${USER_IDENTITY_CLIENT_ID}"
EOF

# Verify the controller created the necessary resources
echo "Waiting for controller to reconcile..."
sleep 5

echo "Checking ConfigMap:"
kubectl get configmap acr-identity-binding-mappings -n kube-system -o yaml

echo "Checking ClusterRoles:"
kubectl get clusterrole -l app=identity-mapping-controller
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
sed -e "s/{{ACR_NAME}}/${ACR_NAME}/g" -e "s/{{SNI_NAME}}/${SNI_NAME}/g" -e "s/{{DEFAULT_CLIENT_ID}}/${USER_IDENTITY_CLIENT_ID}/g" k8s-templates/configure-nodes.yaml | kubectl apply -f -

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
