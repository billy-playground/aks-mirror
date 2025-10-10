# AKS Workload Identity Setup Guide

This guide walks you through setting up workload identity on your Azure Kubernetes Service (AKS) cluster. Workload identity allows your Kubernetes workloads to securely access Azure resources using Azure Active Directory (Azure AD) without storing credentials in your code or configuration.

## Prerequisites

- Azure CLI installed and configured
- kubectl installed
- An active Azure subscription

## Step 1: Create a Resource Group

```bash
export RANDOM_ID="$(openssl rand -hex 3)"
export RESOURCE_GROUP="rg-aks-mirror-demo-$RANDOM_ID"
export LOCATION="southeastasia"

az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
```

## Step 2: Create an AKS Cluster

```bash
export CLUSTER_NAME="cluster-aks-mirror-demo-$RANDOM_ID"

az aks create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${CLUSTER_NAME}" \
    --location "${LOCATION}" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --generate-ssh-keys
```

## Step 3: Retrieve the OIDC Issuer URL

```bash
export AKS_OIDC_ISSUER="$(az aks show --name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query "oidcIssuerProfile.issuerUrl" \
    --output tsv)"
```

## Step 4: Create a Managed Identity

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

## Step 5: Create a Kubernetes Service Account

```bash
az aks get-credentials --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --overwrite-existing

export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa$RANDOM_ID"
export TENANT_ID="$(az account show --query tenantId --output tsv)"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "${USER_ASSIGNED_CLIENT_ID}"
    kubernetes.azure.com/acr-client-id: "${USER_ASSIGNED_CLIENT_ID}"
    kubernetes.azure.com/acr-tenant-id: "${TENANT_ID}"
  name: "${SERVICE_ACCOUNT_NAME}"
  namespace: "${SERVICE_ACCOUNT_NAMESPACE}"
EOF
```

## Step 6: Create the Federated Identity Credential

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
