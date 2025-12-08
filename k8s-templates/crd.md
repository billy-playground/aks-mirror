# Identity Binding CRD Summary

## Overview

A Kubernetes Custom Resource Definition (CRD) and controller system that manages Azure identity bindings for service accounts in AKS clusters. The system automates the creation and management of RBAC resources needed for service accounts to use Azure managed identities via the `sa-exchange` mechanism.

## Architecture

### Key Components

1. **IdentityMapping CRD** - Custom resource for declaring identity bindings
2. **Identity Mapping Controller** - Shell-based Kubernetes operator that watches and reconciles
3. **sa-exchange ServiceAccount** - Single cluster-wide service account in `kube-system` 
4. **ConfigMap** - Stores client ID to service account mappings
5. **Per-ClientID RBAC** - ClusterRole + ClusterRoleBinding for each unique client ID

### Data Model

```yaml
spec:
  bindings:
    "<azure-client-id>":
      serviceAccounts:
      - "namespace:service-account-name"
      - "namespace:service-account-name"
```

**Key Design Decisions:**
- **Client ID as key**: Makes it explicit which identity is shared across service accounts
- **Service accounts as array**: List of `namespace:name` strings that can use this identity
- **Automatic deduplication**: Uses `x-kubernetes-list-type: set` in CRD schema
- **Pattern validation**: Regex validates `namespace:name` format

## Files Added

### 1. identity-mapping-crd.yaml

**Purpose**: Defines the IdentityMapping custom resource

**Key Features**:
- Cluster-scoped resource
- Map structure: `clientId -> serviceAccounts[]`
- Built-in deduplication via `x-kubernetes-list-type: set`
- Pattern validation: `^[a-z0-9]([-a-z0-9]*[a-z0-9])?:[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
- Status subresource for tracking reconciliation
- Short name alias: `ibc`

**Schema**:
```yaml
spec:
  bindings:
    <client-id>:
      serviceAccounts: [string] # array with automatic deduplication
status:
  conditions: []
  processedBindings:
    <client-id>:
      serviceAccounts: []
      clusterRoleName: string
      clusterRoleBindingName: string
```

### 2. identity-mapping-controller.yaml

**Purpose**: Kubernetes controller that reconciles IdentityMapping resources

**What it does**:

1. **Watches** IdentityMapping resources for changes
2. **Ensures** `sa-exchange` ServiceAccount exists in `kube-system`
3. **Updates** ConfigMap `acr-identity-binding-mappings` with current bindings
4. **Creates/Updates** ClusterRole for each unique client ID:
   - Name: `ib-exchange-{clientId}`
   - Rule: `use-managed-identity` verb for the client ID resource
5. **Creates/Updates** ClusterRoleBinding for each client ID:
   - Binds ClusterRole to `sa-exchange` ServiceAccount
6. **Cleans up** unused RBAC when client IDs are removed
7. **Updates** status with reconciliation results

**Controller Details**:
- Language: Python 3.11
- Dependencies: kubernetes==28.1.0
- Deployment: Single replica in `kube-system`
- Resources: 100m CPU / 128Mi memory (request), 500m CPU / 512Mi memory (limit)
- RBAC: Full access to CRDs, ClusterRoles, ClusterRoleBindings, ConfigMaps, ServiceAccounts

**Controller Logic**:
```python
# Pseudocode
for each client_id in bindings:
    service_accounts = deduplicate(bindings[client_id].serviceAccounts)
    
    # Update ConfigMap
    configmap[client_id] = "ns1:sa1,ns2:sa2,..."
    
    # Create RBAC
    create_cluster_role(
        name=f"ib-exchange-{client_id}",
        rules=[{
            verb: "use-managed-identity",
            apiGroup: "cid.wi.aks.azure.com",
            resource: client_id
        }]
    )
    
    create_cluster_role_binding(
        name=f"ib-exchange-{client_id}",
        roleRef=f"ib-exchange-{client_id}",
        subjects=[{
            kind: "ServiceAccount",
            name: "sa-exchange",
            namespace: "kube-system"
        }]
    )
```

### 3. identity-mapping-example.yaml

**Purpose**: Example IdentityMapping resource

**Shows**:
- How to structure the bindings map
- Multiple client IDs with different service accounts
- Proper `namespace:name` format
- Comments explaining deduplication

**Example Structure**:
```yaml
apiVersion: aks.azure.com/v1alpha1
kind: IdentityMapping
metadata:
  name: default-identity-mappings
spec:
  bindings:
    "00000000-0000-0000-0000-000000000001":
      serviceAccounts:
      - "default:workload-sa-1"
      - "default:workload-sa-2"
      - "production:api-service"
    
    "00000000-0000-0000-0000-000000000002":
      serviceAccounts:
      - "production:backend-service"
      - "staging:test-service"
```

## How It Works

### Workflow

1. **User creates/updates** IdentityMapping resource
2. **Controller watches** and detects the change
3. **Controller reconciles**:
   - Ensures `sa-exchange` exists
   - Updates ConfigMap with client ID → service accounts mapping
   - Creates ClusterRole for each unique client ID
   - Creates ClusterRoleBinding binding role to `sa-exchange`
   - Removes RBAC for deleted client IDs
4. **Status updated** with reconciliation results

### ConfigMap Structure

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: acr-identity-binding-mappings
  namespace: kube-system
data:
  "client-id-1": "namespace1:sa1,namespace2:sa2,namespace3:sa3"
  "client-id-2": "namespace4:sa4,namespace5:sa5"
```

### RBAC Structure

For each client ID, creates:

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ib-exchange-{clientId}
  labels:
    app: identity-mapping-controller
    client-id: {clientId}
rules:
- verbs: ["use-managed-identity"]
  apiGroups: ["cid.wi.aks.azure.com"]
  resources: ["{clientId}"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ib-exchange-{clientId}
  labels:
    app: identity-mapping-controller
    client-id: {clientId}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ib-exchange-{clientId}
subjects:
- kind: ServiceAccount
  name: sa-exchange
  namespace: kube-system
```

## Installation

```bash
# 1. Install CRD
kubectl apply -f k8s-templates/identity-mapping-crd.yaml

# 2. Deploy controller
kubectl apply -f k8s-templates/identity-mapping-controller.yaml

# 3. Create bindings
kubectl apply -f k8s-templates/identity-mapping-example.yaml
```

## Usage

### Add New Client ID Binding

```bash
kubectl edit identitymapping default-identity-mappings
```

```yaml
spec:
  bindings:
    "new-namespace:new-service-account": "new-client-id"
```

### Add Service Account to Existing Client ID

```bash
kubectl edit identitymapping default-identity-mappings
```

```yaml
spec:
  bindings:
    "existing-namespace:existing-sa": "existing-client-id"
    "new-namespace:new-sa": "existing-client-id"  # Add this
```

### View Current Bindings

```bash
# View ConfigMap
kubectl get configmap acr-identity-binding-mappings -n kube-system -o yaml

# View status
kubectl get identitymapping default-identity-mappings -o yaml

# View created RBAC
kubectl get clusterrole -l app=identity-mapping-controller
kubectl get clusterrolebinding -l app=identity-mapping-controller
```

## Key Features

### 1. Automatic Deduplication
- **API Level**: CRD uses `x-kubernetes-list-type: set` for automatic deduplication
- **Controller Level**: Uses Python `set()` for additional safety
- **ConfigMap**: Stores sorted, deduplicated list

### 2. Automatic Cleanup
- Controller tracks RBAC by labels
- When client ID removed from bindings, associated RBAC automatically deleted
- No manual cleanup needed

### 3. Single sa-exchange
- One service account per cluster
- All client IDs bind to this single account
- Simplifies management and reduces resources

### 4. Declarative Management
- All configuration in one place (IdentityMapping)
- Add/remove bindings by editing the resource
- Controller handles all reconciliation

### 5. Status Tracking
- Shows reconciliation state
- Lists processed bindings
- Displays created RBAC resources

## Troubleshooting

### View Controller Logs
```bash
kubectl logs -n kube-system -l app=identity-mapping-controller -f
```

### Check Controller Status
```bash
kubectl get pods -n kube-system -l app=identity-mapping-controller
```

### Verify sa-exchange
```bash
kubectl get serviceaccount sa-exchange -n kube-system
```

### Debug RBAC Creation
```bash
# List all ClusterRoles
kubectl get clusterrole -l app=identity-mapping-controller

# Describe specific role
kubectl describe clusterrole ib-exchange-{clientId}

# Check binding
kubectl describe clusterrolebinding ib-exchange-{clientId}
```

### Common Issues

1. **Controller not creating RBAC**
   - Check controller logs for errors
   - Verify CRD is installed: `kubectl get crd identitymappings.aks.azure.com`
   - Check controller has proper RBAC permissions

2. **Duplicates in ConfigMap**
   - Should not happen due to deduplication
   - Check controller logs for warnings
   - Verify CRD has `x-kubernetes-list-type: set`

3. **Old RBAC not cleaned up**
   - Check controller logs for cleanup errors
   - Verify labels on ClusterRoles: `app=identity-mapping-controller,client-id={id}`
   - Manually delete if needed: `kubectl delete clusterrole ib-exchange-{clientId}`

## Limitations

- **Cluster-scoped resource**: Only one IdentityMapping recommended per cluster
- **Client ID uniqueness**: Each client ID should appear once in the bindings map
- **Service account format**: Must be `namespace:name` (validated by regex)
- **Controller single replica**: No HA support (could be added with leader election)

## Future Enhancements

- [ ] Namespace-scoped variant for multi-tenant clusters
- [ ] Webhook validation for additional constraints
- [ ] Metrics and observability
- [ ] Leader election for HA controller
- [ ] Support for cross-namespace service account references
- [ ] Integration with Azure identity binding APIs
