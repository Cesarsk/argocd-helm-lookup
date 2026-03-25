#!/bin/bash
set -eo pipefail

# CMP Generate Script
#
# This script is the core of the CMP sidecar. It runs every time ArgoCD
# renders a chart that has the cmp-lookup annotation.
#
# What it does:
#   1. Builds a kubeconfig from the pod's ServiceAccount
#   2. Reads a ConfigMap via an inline Helm lookup()
#   3. If values-dynamic.yaml exists, substitutes {placeholders} with
#      ConfigMap values and passes them as --set flags to helm template
#   4. Renders the chart
#
# Configuration (via environment variables on the CMP sidecar):
#   CMP_CONFIGMAP_NAME       Name of the ConfigMap to read (default: cluster-metadata)
#   CMP_CONFIGMAP_NAMESPACE  Namespace of the ConfigMap    (default: kube-system)
#   CMP_DYNAMIC_VALUES_FILE  Name of the mapping file      (default: values-dynamic.yaml)
#
# Only uses tools available in the ArgoCD image: bash, helm, grep, sed.
# This script is generic — it never needs to change when new ConfigMap
# keys or charts are added.

# -- Configuration --
CONFIGMAP_NAME="${CMP_CONFIGMAP_NAME:-cluster-metadata}"
CONFIGMAP_NS="${CMP_CONFIGMAP_NAMESPACE:-kube-system}"
DYNAMIC_VALUES="${CMP_DYNAMIC_VALUES_FILE:-values-dynamic.yaml}"

APP_NAME="${1:-${ARGOCD_APP_NAME:-app}}"
CHART_DIR="${2:-.}"
NAMESPACE="${3:-${ARGOCD_APP_NAMESPACE:-default}}"

# -- Build kubeconfig from ServiceAccount credentials --
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

export KUBECONFIG=/tmp/cmp-kubeconfig
cat > "$KUBECONFIG" << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: $CA
    server: https://kubernetes.default.svc
  name: default
contexts:
- context: {cluster: default, namespace: $NAMESPACE, user: default}
  name: default
current-context: default
users:
- name: default
  user: {token: $SA_TOKEN}
EOF

# -- Read ConfigMap via inline Helm lookup --
# Since the ArgoCD image has no curl/kubectl, we use a tiny inline Helm
# chart with lookup() to query the K8s API via --dry-run=server.
# The template outputs each ConfigMap key as a parseable "# META:key=value" line.
LOOKUP_DIR=/tmp/cmp-lookup
mkdir -p "$LOOKUP_DIR/templates"
cat > "$LOOKUP_DIR/Chart.yaml" <<< "apiVersion: v2
name: lookup
version: 0.0.1"
cat > "$LOOKUP_DIR/templates/t.yaml" << TMPL
{{- \$cm := (lookup "v1" "ConfigMap" "$CONFIGMAP_NS" "$CONFIGMAP_NAME") }}
{{- if \$cm }}
{{- range \$k, \$v := \$cm.data }}
# META:{{ \$k }}={{ \$v }}
{{- end }}
{{- end }}
TMPL

declare -A META
LOOKUP_OUT=$(helm template lookup "$LOOKUP_DIR" -n "$NAMESPACE" --dry-run=server 2>/dev/null) || true
while IFS='=' read -r key value; do
  # Validate: alphanumeric keys only, reject shell metacharacters in values
  if [[ "$key" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] && [[ ! "$value" =~ [\$\`\;\|\&\>\<\(\)\{\}] ]]; then
    META["$key"]="$value"
  fi
done < <(echo "$LOOKUP_OUT" | grep '^# META:' | sed 's/^# META://')
rm -rf "$LOOKUP_DIR"

[[ ${#META[@]} -eq 0 ]] && echo "WARNING: ConfigMap $CONFIGMAP_NS/$CONFIGMAP_NAME not found or empty" >&2

# -- Build --set flags from dynamic values file --
# Each line maps a Helm value path to a template with {configMapKey} placeholders.
# Example: metrics-server.replicas: "{replicas}"
# Becomes: --set metrics-server.replicas=5  (if ConfigMap has replicas=5)
SET_FLAGS=""
if [ -f "$CHART_DIR/$DYNAMIC_VALUES" ]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" ]] && continue

    helm_path="${line%%: *}"
    template="${line#*: }"
    template="${template#\"}"
    template="${template%\"}"

    # Replace {key} placeholders with actual ConfigMap values
    resolved="$template"
    for key in "${!META[@]}"; do
      resolved="${resolved//\{$key\}/${META[$key]}}"
    done

    # Skip if any placeholder wasn't resolved
    if [[ "$resolved" =~ \{[a-zA-Z] ]]; then
      echo "WARNING: unresolved placeholder in $helm_path: $resolved" >&2
      continue
    fi

    # Use --set for numbers/booleans so Helm types them correctly
    if [[ "$resolved" =~ ^(true|false|[0-9]+)$ ]]; then
      SET_FLAGS="$SET_FLAGS --set $helm_path=$resolved"
    else
      SET_FLAGS="$SET_FLAGS --set-string $helm_path=$resolved"
    fi
  done < "$CHART_DIR/$DYNAMIC_VALUES"
fi

# -- Render --
# shellcheck disable=SC2086
helm template "$APP_NAME" "$CHART_DIR" \
  -n "$NAMESPACE" \
  --include-crds \
  --dry-run=server \
  -f "$CHART_DIR/values.yaml" \
  $SET_FLAGS
