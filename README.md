Medium article: https://lucacesarano.medium.com/a-small-and-easy-example-to-make-helm-lookup-work-in-argo-cd-92b18bd68593

# ArgoCD CMP — Dynamic Value Injection

A Config Management Plugin (CMP) that injects cluster-specific values into Helm charts at render time, removing the need to hardcode per-cluster values in chart configurations.

## Problem

ArgoCD runs `helm template` offline. Cluster-specific values (account IDs, regions, VPC IDs) must be hardcoded into ArgoCD configurations. Adding or updating a value requires propagating changes across every cluster individually.

## Solution

A CMP sidecar on the ArgoCD repo-server that reads a `cluster-metadata` ConfigMap and injects values into Helm charts. Two approaches are supported:

| Approach | How | Best for |
|----------|-----|----------|
| **Mapping file** (recommended) | CMP reads ConfigMap, substitutes `{placeholders}` in `values-dynamic.yaml`, passes `--set` flags to `helm template` | Any chart — upstream or custom — without modification |
| **Helm lookup()** (legacy) | CMP runs `helm template --dry-run=server`, giving charts API access to call `lookup()` directly in templates | Custom charts that need conditional rendering based on cluster state |

The mapping approach is recommended for all use cases. See [Approach Comparison](#approach-comparison) for a detailed analysis.

## How the Mapping Approach Works

```
cluster-metadata ConfigMap (kube-system, created during cluster provisioning)
         |
         '--- CMP generate.sh
              reads ConfigMap via K8s API
              reads values-dynamic.yaml from chart directory
              substitutes {placeholders} with ConfigMap values
              passes --set flags to helm template
```

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

At render time, the CMP script reads the ConfigMap (`accountId=123456789012`, `replicas=5`), substitutes the placeholders, and passes `--set-string ...role-arn=arn:aws:iam::123456789012:role/metrics-server --set metrics-server.replicas=5` to `helm template`. The upstream chart is never modified.

## How the lookup() Approach Works

Charts opt in via the same annotation in `Chart.yaml`. The CMP runs `helm template --dry-run=server`, which gives Helm access to the Kubernetes API. Chart templates can then call `lookup()` directly:

```yaml
{{- $meta := (lookup "v1" "ConfigMap" "kube-system" "cluster-metadata") }}
{{- if $meta }}
  region: {{ $meta.data.region }}
  accountId: {{ $meta.data.accountId }}
{{- end }}
```

This requires modifying chart templates. It is demonstrated in `approach-1-lookup-old/` but is not the recommended pattern.

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

This repo contains two demo setups and a shared ConfigMap chart:

### cluster-metadata

**Path:** `cluster-metadata/`

A Helm chart that deploys the `cluster-metadata` ConfigMap. In production, this is created during cluster provisioning. For the demo it's deployed as a standalone chart.

```yaml
data:
  accountId: "123456789012"
  region: "eu-central-1"
  clusterName: "example_cluster"
  vpcId: "vpc-0a12bc322f456"
  environment: "dev"
  replicas: "3"
```

### Approach 1: Helm lookup() (legacy)

**Path:** `approach-1-lookup-old/`

Two identical charts — one with the CMP annotation, one without — demonstrating that `lookup()` works when the CMP is active and fails without it.

| Chart | CMP annotation | Result |
|-------|---------------|--------|
| `chart-with-cmp/` | Yes | `lookup()` reads ConfigMap, values injected |
| `chart-without-cmp/` | No | `nil pointer` — offline render, no API access |

### Approach 2: Mapping file (recommended)

**Path:** `approach-2-upstream-new/`

An unmodified upstream metrics-server chart with dynamic value injection via `values-dynamic.yaml`:
- `replicas` set from ConfigMap
- IRSA role ARN constructed from `accountId`

No chart templates modified. The mapping file is the only bridge between the ConfigMap and the chart.

## Operations: Changing a Value in Production

Example: scaling metrics-server from 3 to 5 replicas.

**Single action: update the `cluster-metadata` ConfigMap.**

1. **Update the variable** — change `replicas: "3"` to `replicas: "5"` in the cluster-metadata ConfigMap
2. **Apply the change** — update the ConfigMap in the cluster
3. **ArgoCD refreshes** — CMP re-reads the ConfigMap, generates `--set metrics-server.replicas=5`, detects OutOfSync
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
   -> CMP runs generate.sh
   -> Reads the live ConfigMap from the cluster, reads values-dynamic.yaml
   -> Returns rendered manifests to ArgoCD

2. COMPARE (diff)
   ArgoCD compares rendered manifests vs live cluster state
   -> Desired: replicas=3, Live: replicas=5
   -> Result: OutOfSync

3. SYNC (apply)
   ArgoCD applies the diff to the cluster (standard kubectl apply)
   -> No CMP involvement
```

### Refresh types

- **Refresh** — re-renders manifests via CMP (reads the live ConfigMap), compares against cluster state. This is all you need when a ConfigMap value changes.
- **Hard Refresh** — same as above, but also re-fetches the Git repo and invalidates the Helm dependency cache. Only needed when the chart source in Git changed.

## Approach Comparison

This section evaluates whether `lookup()` in chart templates is ever needed, or whether the mapping approach (`values-dynamic.yaml`) is sufficient.

**Short answer: the mapping approach covers all production use cases.**

### Mapping approach strengths

- Inject any scalar value from a ConfigMap into any Helm value path
- Construct strings from multiple ConfigMap values (e.g., ARN from `{accountId}`)
- Works with any chart — upstream or custom — without template modification
- Fully reviewable (the mapping file is simple YAML in Git)
- Testable offline (no cluster needed to see what `--set` flags will be generated)
- Predictable (same ConfigMap = same output, always)

### Where lookup() offers something different

There are four categories where `lookup()` does something the mapping can't. In each case, a better alternative exists:

**1. Conditional rendering based on cluster state**

`lookup()` can check if a CRD or resource exists and conditionally render templates. The mapping approach only injects values.

Alternative: In a controlled platform with ArgoCD sync waves, deployment ordering is guaranteed. Feature toggles via ConfigMap booleans (`istioEnabled: "true"`) combined with chart feature flags are simpler and more predictable than runtime CRD checks.

**2. Reading from resources other than the configured ConfigMap**

`lookup()` can read any resource — Secrets, other ConfigMaps, Services.

Alternative: Secrets should go through External Secrets Operator (ESO), not Helm rendering — reading secrets at template time puts them in ArgoCD's manifest cache, which is a security concern. Other metadata can be consolidated into the single `cluster-metadata` ConfigMap.

**3. Idempotent secret generation**

`lookup()` can check if a Secret exists before generating a new one, preventing password rotation on upgrades.

Alternative: ESO manages secrets externally. Helm should not generate passwords. This is the one scenario where `lookup()` adds genuine value for users without a secrets operator.

**4. Dynamic cluster queries**

`lookup()` can query nodes, pods, or other resources to compute values (e.g., set replicas based on node count).

Alternative: This is fragile — values are baked in at render time and don't adapt to changes. HPA handles dynamic scaling. For static sizing, put the value in the ConfigMap.

### Summary

| Scenario | lookup() needed? | Alternative |
|----------|-----------------|-------------|
| Inject ConfigMap values into charts | No | Mapping (simpler, testable) |
| Conditional rendering (CRD exists?) | No | Deployment ordering + ConfigMap booleans |
| Read Secrets at render time | No (security risk) | ESO |
| Read other ConfigMaps | No | Consolidate into cluster-metadata |
| Idempotent secret generation | Only without ESO | ESO |
| Dynamic cluster queries | No | HPA / ConfigMap |

**Recommendation: use the mapping approach for everything.** The `lookup()` capability exists as a side effect of how the CMP works (`--dry-run=server`) and is demonstrated in `approach-1-lookup-old/` for completeness, but is not the recommended pattern.

## Files

```
cmp-installation/
  cmp-rbac.yaml                    # ClusterRole + ClusterRoleBinding
  cmp-plugin.yaml                  # Plugin ConfigMap reference
  generate.sh                      # Generate script (source of truth)
  repo-server-patch.yaml           # Sidecar deployment patch
cluster-metadata/                  # ConfigMap chart (for demo purposes)
approach-1-lookup-old/             # lookup() demo (legacy)
  chart-with-cmp/                  #   CMP enabled — lookup() works
  chart-without-cmp/               #   No CMP — lookup() fails
approach-2-upstream-new/           # Mapping demo (recommended)
  metrics-server/                  #   Upstream chart with values-dynamic.yaml
```

## Related

- [ArgoCD CMP Docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/)
- [ArgoCD Issue #21745](https://github.com/argoproj/argo-cd/issues/21745) — Native `--dry-run=server` proposal
