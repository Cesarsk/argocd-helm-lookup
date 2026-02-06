# ArgoCD Helm Lookup

Enable Helm's `lookup()` function in ArgoCD using a Config Management Plugin (CMP) sidecar.

## The Problem

Helm's [`lookup()`](https://helm.sh/docs/chart_template_guide/functions_and_pipelines/#using-the-lookup-function) function queries the Kubernetes API at render time to read existing resources. This is useful for:

- Reading cluster metadata (account IDs, regions, VPC IDs) from a ConfigMap
- Checking if a CRD exists before creating a resource
- Dynamically configuring charts based on existing cluster state

**However, ArgoCD renders Helm charts offline** using `helm template` (without `--dry-run=server`). This means `lookup()` always returns an empty dict `{}`, making it useless.

```yaml
# This ALWAYS returns empty in ArgoCD's default rendering:
{{- $config := (lookup "v1" "ConfigMap" "kube-system" "my-config") }}
# $config = map[] (empty)
```

## The Solution

Use a **Config Management Plugin (CMP)** sidecar on the ArgoCD repo-server that renders charts with `helm template --dry-run=server`, which connects to the Kubernetes API and makes `lookup()` work.

### Architecture

```
ArgoCD repo-server Pod
├── repo-server (main container)     # Default: offline helm template
└── cmp-helm-lookup (sidecar)        # CMP: helm template --dry-run=server
        │
        ├── Reads ServiceAccount token
        ├── Builds kubeconfig pointing to kubernetes.default.svc
        └── Runs: helm template <app> . -n <ns> --dry-run=server --include-crds
```

The CMP sidecar:
1. **Discovers** charts that opt in via a `Chart.yaml` annotation
2. **Builds** a kubeconfig from the pod's mounted ServiceAccount token
3. **Renders** templates with `--dry-run=server`, enabling API access for `lookup()`

### How CMP Plugin Discovery Works

ArgoCD CMP uses a **discover** mechanism to decide which plugin handles a given chart. Our plugin checks for a specific annotation in `Chart.yaml`:

```yaml
# The plugin runs this command to check if it should handle the chart:
discover:
  find:
    command: [sh, -c, "grep -q 'cmp-lookup.*enabled' Chart.yaml && echo found"]
```

Only charts that include this annotation in their `Chart.yaml` are rendered by the CMP plugin:

```yaml
annotations:
  argocd.argoproj.io/cmp-lookup: "enabled"
```

All other charts continue to use ArgoCD's default offline rendering.

## Installation

### Prerequisites

- ArgoCD installed (Helm-based deployment recommended)
- `kubectl` access to the cluster
- The repo-server must have `automountServiceAccountToken: true` (default in ArgoCD Helm chart)

### Step 1: RBAC - Grant repo-server API read access

The repo-server ServiceAccount needs permission to read resources via `lookup()`.

```bash
kubectl apply -f manifests/cmp-rbac.yaml
```

<details>
<summary>manifests/cmp-rbac.yaml</summary>

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-repo-server-lookup
rules:
  - apiGroups: [""]
    resources: [configmaps, secrets, services, namespaces]
    verbs: [get, list]
  - apiGroups: ["apps"]
    resources: [deployments, statefulsets, daemonsets]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-repo-server-lookup
subjects:
  - kind: ServiceAccount
    name: argo-cd-argocd-repo-server  # Adjust to match your ArgoCD installation
    namespace: argocd                  # Adjust to match your ArgoCD namespace
roleRef:
  kind: ClusterRole
  name: argocd-repo-server-lookup
  apiGroup: rbac.authorization.k8s.io
```

</details>

> **Note:** Adjust the ServiceAccount `name` and `namespace` to match your ArgoCD installation. Common patterns:
> - Helm install named `argo-cd` in namespace `argocd`: SA is `argo-cd-argocd-repo-server`
> - Helm install named `argocd` in namespace `argocd`: SA is `argocd-repo-server`

### Step 2: CMP Plugin ConfigMap

Deploy the plugin definition that tells ArgoCD how to render charts with lookup support.

```bash
kubectl apply -f manifests/cmp-plugin.yaml
```

<details>
<summary>manifests/cmp-plugin.yaml</summary>

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-plugin
  namespace: argocd  # Adjust to match your ArgoCD namespace
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: helm-with-lookup
    spec:
      version: v1.0
      discover:
        find:
          command: [sh, -c, "grep -q 'cmp-lookup.*enabled' Chart.yaml && echo found"]
      init:
        command: [sh, -c, "test -f Chart.lock && helm dependency build || true"]
      generate:
        command:
          - sh
          - -c
          - |
            CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
            TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
            export KUBECONFIG=/tmp/kube
            cat > $KUBECONFIG << EOF
            apiVersion: v1
            kind: Config
            clusters:
            - cluster:
                certificate-authority: $CA
                server: https://kubernetes.default.svc
              name: default
            contexts:
            - context: {cluster: default, namespace: $ARGOCD_APP_NAMESPACE, user: default}
              name: default
            current-context: default
            users:
            - name: default
              user: {token: $TOKEN}
            EOF
            helm template $ARGOCD_APP_NAME . -n $ARGOCD_APP_NAMESPACE --dry-run=server --include-crds
```

</details>

#### How the generate command works

The `generate` section is the core of the plugin. Here's what each part does:

1. **Read the ServiceAccount credentials** mounted into the pod:
   ```bash
   CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
   TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
   ```

2. **Build a kubeconfig** that points to the in-cluster API server:
   ```bash
   export KUBECONFIG=/tmp/kube
   cat > $KUBECONFIG << EOF
   # ... kubeconfig pointing to https://kubernetes.default.svc
   EOF
   ```

3. **Render with server-side dry-run**, which enables `lookup()`:
   ```bash
   helm template $ARGOCD_APP_NAME . -n $ARGOCD_APP_NAMESPACE --dry-run=server --include-crds
   ```

The `$ARGOCD_APP_NAME` and `$ARGOCD_APP_NAMESPACE` environment variables are automatically set by ArgoCD for each application.

### Step 3: Add CMP sidecar to repo-server

Patch the ArgoCD repo-server deployment to add the CMP sidecar container.

```bash
kubectl apply -f manifests/repo-server-patch.yaml
```

<details>
<summary>manifests/repo-server-patch.yaml</summary>

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argo-cd-argocd-repo-server  # Adjust to match your deployment name
  namespace: argocd                  # Adjust to match your ArgoCD namespace
spec:
  template:
    spec:
      volumes:
        - name: cmp-plugin
          configMap:
            name: cmp-plugin
        - name: cmp-tmp
          emptyDir: {}
      containers:
        - name: cmp-helm-lookup
          command: [/var/run/argocd/argocd-cmp-server]
          image: quay.io/argoproj/argocd:v2.12.1  # Match your ArgoCD version
          securityContext:
            runAsNonRoot: true
            runAsUser: 999
          volumeMounts:
            - name: cmp-plugin
              mountPath: /home/argocd/cmp-server/config/plugin.yaml
              subPath: plugin.yaml
            - name: var-files
              mountPath: /var/run/argocd
            - name: cmp-tmp
              mountPath: /tmp
            - name: plugins
              mountPath: /home/argocd/cmp-server/plugins
```

</details>

> **Important:** The sidecar image version should match your ArgoCD version. The `var-files` and `plugins` volumes already exist in the default ArgoCD repo-server deployment.

#### If you manage ArgoCD with Helm values

Instead of patching, add the sidecar directly to your ArgoCD Helm values:

```yaml
repoServer:
  volumes:
    - name: cmp-plugin
      configMap:
        name: cmp-plugin
    - name: cmp-tmp
      emptyDir: {}
  extraContainers:
    - name: cmp-helm-lookup
      command: [/var/run/argocd/argocd-cmp-server]
      image: quay.io/argoproj/argocd:v2.12.1  # Match your ArgoCD version
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
      volumeMounts:
        - name: cmp-plugin
          mountPath: /home/argocd/cmp-server/config/plugin.yaml
          subPath: plugin.yaml
        - name: var-files
          mountPath: /var/run/argocd
        - name: cmp-tmp
          mountPath: /tmp
        - name: plugins
          mountPath: /home/argocd/cmp-server/plugins
```

### Step 4: Create a metadata ConfigMap (optional)

A useful pattern is to create a cluster-wide metadata ConfigMap that any chart can read via `lookup()`:

```bash
kubectl apply -f manifests/cluster-metadata.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-metadata
  namespace: kube-system
data:
  accountId: "123456789012"
  region: "eu-central-1"
  vpcId: "vpc-0abc123def456"
  clusterName: "my-cluster"
  environment: "production"
```

This gives every chart access to cluster context without hardcoding values or passing them through Helm overrides.

## Demo: Using lookup() in a chart

The `demo-chart/` directory contains a working example.

### Opt in to CMP rendering

Add the annotation to `Chart.yaml`:

```yaml
apiVersion: v2
name: my-chart
version: 1.0.0
annotations:
  argocd.argoproj.io/cmp-lookup: "enabled"  # This triggers the CMP plugin
```

### Use lookup() in templates

```yaml
{{- $aws := (lookup "v1" "ConfigMap" "kube-system" "aws-metadata") }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
    spec:
      containers:
      - name: app
        image: nginx:alpine
        env:
        - name: AWS_ACCOUNT_ID
          value: {{ $aws.data.accountId | quote }}
        - name: AWS_REGION
          value: {{ $aws.data.region | quote }}
        - name: CLUSTER_NAME
          value: {{ $aws.data.clusterName | quote }}
        - name: ENVIRONMENT
          value: {{ $aws.data.environment | quote }}
```

### Deploy and verify

```bash
# After syncing in ArgoCD:
kubectl exec -n demo deploy/cmp-demo -- env | grep -E 'AWS|CLUSTER|ENVIRONMENT'
# AWS_ACCOUNT_ID=123456789012
# AWS_REGION=eu-central-1
# CLUSTER_NAME=my-cluster
# ENVIRONMENT=production
```

## Verification

After installation, verify the CMP sidecar is running:

```bash
# Check repo-server has the sidecar
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server \
  -o jsonpath='{.items[0].spec.containers[*].name}'
# Expected: repo-server cmp-helm-lookup

# Check RBAC
kubectl get clusterrole argocd-repo-server-lookup
kubectl get clusterrolebinding argocd-repo-server-lookup

# Check plugin ConfigMap
kubectl get configmap cmp-plugin -n argocd

# Check metadata ConfigMap (if created)
kubectl get configmap aws-metadata -n kube-system -o yaml
```

## How it works end-to-end

```
1. Developer adds annotation to Chart.yaml:
   argocd.argoproj.io/cmp-lookup: "enabled"

2. ArgoCD detects the chart needs rendering:
   - Checks each CMP plugin's discover command
   - helm-with-lookup: grep -q 'cmp-lookup.*enabled' Chart.yaml → found!

3. CMP sidecar renders the chart:
   - Builds kubeconfig from ServiceAccount token
   - Runs: helm template <app> . -n <ns> --dry-run=server
   - lookup() calls hit the real Kubernetes API
   - ConfigMap values are injected into the rendered manifests

4. ArgoCD applies the rendered manifests to the cluster
```

## Troubleshooting

### lookup() returns empty

- Verify the CMP sidecar is running (check pod containers)
- Verify the `Chart.yaml` has the `argocd.argoproj.io/cmp-lookup: "enabled"` annotation
- Check that the RBAC ClusterRole includes the resource type you're looking up
- Check sidecar logs: `kubectl logs -n argocd <repo-server-pod> -c cmp-helm-lookup`

### Permission denied errors in sidecar logs

- The ClusterRoleBinding must reference the correct ServiceAccount name and namespace
- Verify with: `kubectl auth can-i get configmaps -n kube-system --as=system:serviceaccount:argocd:argo-cd-argocd-repo-server`

### Chart renders with default ArgoCD (not CMP)

- The `discover` command must output something to stdout. Verify: `grep -q 'cmp-lookup.*enabled' Chart.yaml && echo found`
- Ensure the CMP plugin ConfigMap is mounted correctly in the sidecar

### YAML parse error when templating Helm values with conditionals

If you manage ArgoCD via Helm and use `templatefile()` or similar to conditionally include the sidecar in your values, be careful with whitespace-trimming directives. For example, in Terraform's `templatefile`:

```yaml
# WRONG - tilde (~) strips newlines, collapsing YAML keys onto one line:
repoServer:
  replicas: 2
%{~ if enable_cmp ~}
  volumes:
# Renders as: "replicas: 2  volumes:" → YAML parse error!

# CORRECT - no tilde, preserves newlines:
repoServer:
  replicas: 2
%{ if enable_cmp }
  volumes:
# Renders as: "replicas: 2\n\n  volumes:" → valid YAML
```

## Security Considerations

- The CMP sidecar runs with the repo-server's ServiceAccount, which gets **read-only** cluster access via the ClusterRole
- Scope the ClusterRole to only the resource types your charts actually need
- The `--dry-run=server` flag sends manifests to the API server for validation but does **not** persist them
- Only charts that explicitly opt in via the annotation are rendered by the CMP plugin

## Compatibility

Tested with:
- ArgoCD v2.12.x
- Helm v3.x
- Kubernetes 1.28+

## License

MIT
