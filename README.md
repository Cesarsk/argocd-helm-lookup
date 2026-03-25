# ArgoCD CMP — Dynamic Value Injection

A Config Management Plugin (CMP) that injects cluster-specific values into Helm charts at render time, removing the dependency on Terraform templating.

## Problem

ArgoCD runs `helm template` offline. Cluster-specific values (account IDs, regions, VPC IDs) must be hardcoded via Terraform templating into ArgoCD configurations. Adding or updating a value requires Terraform plan/apply cycles and ~60 MRs.

## Solution

A CMP sidecar on the ArgoCD repo-server that reads a `cluster-metadata` ConfigMap and injects values into any Helm chart via a `values-dynamic.yaml` mapping file.

```
cluster-metadata ConfigMap (kube-system, created by Terraform)
         |
         '--- CMP generate.sh
              reads ConfigMap via K8s API
              reads values-dynamic.yaml from chart directory
              builds --set-string flags
              renders chart with helm template
```

The upstream chart is never modified. The mapping file lives in Git alongside the chart.

## How It Works

Each chart that needs dynamic values has three files:

**Chart.yaml** — CMP annotation + upstream dependency:
```yaml
apiVersion: v2
name: metrics-server-wrapper
version: 1.0.0
annotations:
  argocd.argoproj.io/cmp-lookup: "enabled"
dependencies:
  - name: metrics-server
    version: "3.13.0"
    repository: https://kubernetes-sigs.github.io/metrics-server/
```

**values.yaml** — static defaults (things that don't vary per cluster):
```yaml
metrics-server:
  args:
    - --kubelet-insecure-tls
```

**values-dynamic.yaml** — maps ConfigMap keys to chart value paths:
```yaml
# {key} placeholders are replaced with values from the cluster-metadata ConfigMap
metrics-server.serviceAccount.annotations.eks\.amazonaws\.com/role-arn: "arn:aws:iam::{accountId}:role/metrics-server"
metrics-server.replicas: "{replicas}"
```

At render time, the CMP script reads the ConfigMap (`accountId=123456789012`, `replicas=5`), substitutes the placeholders, and passes `--set-string metrics-server.serviceAccount.annotations...=arn:aws:iam::123456789012:role/metrics-server --set metrics-server.replicas=5` to `helm template`.

## Configuration

The CMP sidecar is configured via environment variables on the repo-server deployment:

| Variable | Default | Description |
|----------|---------|-------------|
| `CMP_CONFIGMAP_NAME` | `cluster-metadata` | Name of the ConfigMap to read |
| `CMP_CONFIGMAP_NAMESPACE` | `kube-system` | Namespace of the ConfigMap |
| `CMP_DYNAMIC_VALUES_FILE` | `values-dynamic.yaml` | Name of the mapping file in each chart directory |

## Installation

```bash
kubectl apply -f cmp-installation/cmp-rbac.yaml
kubectl apply -f cmp-installation/cmp-plugin.yaml
kubectl patch deployment argocd-repo-server -n argocd \
  --patch-file cmp-installation/repo-server-patch.yaml
kubectl rollout status deployment/argocd-repo-server -n argocd
```

## Demo

The `` directory contains two experiments:

### Experiment 1: Helm lookup() (custom charts)

**Path:** `approach-1-lookup-old/`

Shows that `lookup()` works with the CMP annotation and fails without it. See [lookup() vs mapping](#lookup-vs-mapping-analysis) for when each approach is appropriate.

| Chart | CMP annotation | Result |
|-------|---------------|--------|
| `chart-with-cmp/` | Yes | `lookup()` reads ConfigMap, values injected |
| `chart-without-cmp/` | No | `nil pointer` — no API access |

### Experiment 2: Upstream chart injection (metrics-server)

**cluster-metadata** — deploys the ConfigMap (in production, Terraform does this):
```yaml
data:
  accountId: "123456789012"
  region: "eu-central-1"
  clusterName: "payments-dev"
  vpcId: "vpc-0abc123def456"
  environment: "dev"
  replicas: "5"
```

**metrics-server** — upstream chart with dynamic value injection:
- `replicas` set from ConfigMap (currently 5)
- IRSA role ARN constructed from `accountId`

## Operations: Changing a Value in Production

Example: scaling metrics-server from 3 to 5 replicas.

**Single action: update the `cluster-metadata` ConfigMap.**

1. **Update the Terraform variable** — change `replicas: "3"` to `replicas: "5"` in the cluster's tfvars
2. **Terraform plan/apply** — updates the ConfigMap in the cluster
3. **ArgoCD auto-syncs** — CMP re-reads the ConfigMap, generates `--set metrics-server.replicas=5`, detects OutOfSync
4. **Deployment scales to 5** — ArgoCD applies the change

**What you DON'T touch:**
- The metrics-server Helm chart (upstream, never modified)
- The `values-dynamic.yaml` (mapping doesn't change, still says `{replicas}`)
- The CMP generate script (generic, never changes)
- ArgoCD Applications (no reconfiguration needed)

## How the CMP Interacts with ArgoCD Sync

The CMP only participates in the **render** phase. It has no role in sync or apply.

```
1. REFRESH (render)
   ArgoCD asks: "what should the cluster look like?"
   → CMP runs generate.sh
   → Reads the live ConfigMap from the cluster, reads values-dynamic.yaml
   → Returns rendered manifests to ArgoCD

2. COMPARE (diff)
   ArgoCD compares rendered manifests vs live cluster state
   → Desired: replicas=3, Live: replicas=5
   → Result: OutOfSync

3. SYNC (apply)
   ArgoCD applies the diff to the cluster (standard kubectl apply)
   → No CMP involvement
```

### Refresh types

- **Refresh** — re-renders manifests via CMP (reads the live ConfigMap), compares against cluster state. This is all you need when a ConfigMap value changes.
- **Hard Refresh** — same as above, but also re-fetches the Git repo and invalidates the Helm dependency cache. Only needed when the chart source in Git changed.

### Timing dependency

The CMP reads the **live ConfigMap in the cluster**, not Git. If the ConfigMap is managed by a separate ArgoCD Application (as in the demo), there's a timing dependency:

1. Git push changes the `cluster-metadata` chart (e.g., `replicas: 3` → `replicas: 5`)
2. ArgoCD syncs the `cluster-metadata` app → ConfigMap updated in the cluster
3. ArgoCD refreshes the `metrics-server` app → CMP reads the **updated** ConfigMap → renders `replicas=5` → detects OutOfSync

If step 3 happens before step 2 (e.g., both apps refresh simultaneously), the CMP reads the **old** ConfigMap and sees no diff. The next refresh cycle (default: 3 minutes) will pick up the change.

In production, where Terraform manages the ConfigMap directly (not via ArgoCD), this timing issue doesn't exist — the ConfigMap is updated before ArgoCD ever refreshes.

## lookup() vs Mapping: Analysis

The CMP sidecar enables two approaches. This section honestly evaluates whether `lookup()` in chart templates is needed, or whether the mapping approach (`values-dynamic.yaml`) is sufficient for all cases.

**Short answer: the mapping approach covers all production use cases. `lookup()` is a capability of the CMP but not a recommended pattern.**

### What the mapping approach can do

- Inject any scalar value from a ConfigMap into any Helm value path
- Construct strings from multiple ConfigMap values (e.g., ARN from `{accountId}`)
- Works with any chart — upstream or custom — without template modification
- Fully reviewable (the mapping file is simple YAML in Git)
- Testable offline (no cluster needed to see what `--set` flags will be generated)
- Predictable (same ConfigMap → same output, always)

### What the mapping approach cannot do

There are four categories where `lookup()` offers something the mapping can't:

#### 1. Conditional rendering based on cluster state

```yaml
{{- if (lookup "apiextensions.k8s.io/v1" "CRD" "" "certificates.cert-manager.io") }}
apiVersion: cert-manager.io/v1
kind: Certificate
...
{{- end }}
```

"Only create this resource if a CRD exists." The mapping approach can't do this — it injects values, not conditional logic.

**However:** In a controlled platform (ArgoCD sync waves, app-of-apps), deployment ordering is guaranteed. You don't need to check if cert-manager is installed — you know it is because Phase 0 runs before Phase 1. If you need a feature toggle, a boolean in the ConfigMap (`istioEnabled: "true"`) combined with the chart's built-in feature flags is simpler and more predictable than a runtime CRD check.

**Verdict: Not needed.** Deployment ordering + ConfigMap booleans replace this.

#### 2. Reading from resources other than the configured ConfigMap

`lookup()` can read any resource — Secrets, other ConfigMaps, Services. The mapping approach reads from one ConfigMap.

**However:**
- **Secrets** should go through External Secrets Operator (ESO), not Helm rendering. Reading secrets at template time means they end up in ArgoCD's rendered manifest cache, which is a security concern.
- **Other ConfigMaps** can be consolidated into the single `cluster-metadata` ConfigMap. If the data exists in the cluster, Terraform can also put it in the metadata ConfigMap.
- **Services/endpoints** are a runtime concern, not a deploy-time concern. A chart shouldn't depend on another service's ClusterIP at render time.

**Verdict: Not needed.** Secrets → ESO. Metadata → consolidate into one ConfigMap.

#### 3. Idempotent secret generation

```yaml
{{- $existing := (lookup "v1" "Secret" .Release.Namespace "grafana-admin") }}
{{- if not $existing }}
apiVersion: v1
kind: Secret
data:
  password: {{ randAlphaNum 32 | b64enc }}
{{- end }}
```

"Generate a random password on first install, don't overwrite on upgrade." Some upstream charts (PostgreSQL, Grafana) use this pattern.

**However:** In a platform where ESO manages secrets, this pattern is unnecessary. Passwords are stored in a secrets manager (AWS Secrets Manager, Vault) and synced to Kubernetes by ESO. Helm never generates passwords.

**Verdict: Not needed if ESO is in place.** For open-source users without ESO, this is the one scenario where `lookup()` adds genuine value.

#### 4. Multi-resource queries

```yaml
{{- $nodes := (lookup "v1" "Node" "" "") }}
{{- $nodeCount := len $nodes.items }}
replicas: {{ min $nodeCount 3 }}
```

"Set replicas based on cluster size." This requires querying resources the mapping approach can't express.

**However:** This is fragile — the replica count is baked in at render time and doesn't adapt if nodes are added later. An HPA (Horizontal Pod Autoscaler) is the correct solution for dynamic scaling. For static sizing, put the value in the ConfigMap.

**Verdict: Not needed.** Use HPA for dynamic scaling, ConfigMap for static sizing.

### Summary

| Scenario | lookup() needed? | Alternative |
|----------|-----------------|-------------|
| Inject ConfigMap values into charts | No | Mapping approach (simpler, testable) |
| Conditional rendering (CRD exists?) | No | Deployment ordering + feature flags in ConfigMap |
| Read Secrets at render time | No (and risky) | ESO |
| Read other ConfigMaps | No | Consolidate into cluster-metadata |
| Idempotent secret generation | Only without ESO | ESO |
| Dynamic cluster queries | No | HPA / ConfigMap |

### Recommendation

**Use the mapping approach (`values-dynamic.yaml`) for everything.** It is simpler, reviewable, testable, and covers all production scenarios.

The `lookup()` capability exists as a side effect of how the CMP works (`--dry-run=server`). It is demonstrated in approach-1 for completeness, but should not be the default pattern. If you find yourself reaching for `lookup()`, consider whether a ConfigMap value or ESO would solve the same problem more cleanly.

## Security

The generate script is hardened:

- **No `eval`** — ConfigMap values parsed via `read`, never executed
- **No `envsubst`** — prevents leaking system env vars
- **Input validation** — rejects keys/values with shell metacharacters
- **`--set-string`** — values treated as strings (numbers/booleans use `--set`)
- **Read-only RBAC** — repo-server only has `get`/`list` permissions

## Files

```
cmp-installation/
├── cmp-rbac.yaml                  # ClusterRole + ClusterRoleBinding
├── cmp-plugin.yaml                # Plugin ConfigMap reference
├── generate.sh                    # Generate script (source of truth)
└── repo-server-patch.yaml         # Sidecar deployment patch
cluster-metadata/                  # ConfigMap chart (Terraform equivalent)
approach-1-lookup-old/             # lookup() demo (custom charts)
├── chart-with-cmp/                #   CMP enabled — lookup() works
└── chart-without-cmp/             #   No CMP — lookup() fails
approach-2-upstream-new/
└── metrics-server/                # Upstream chart with values-dynamic.yaml
```

## Related

- [ArgoCD CMP Docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/)
- [ArgoCD Issue #21745](https://github.com/argoproj/argo-cd/issues/21745) — Native `--dry-run=server` proposal
