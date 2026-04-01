#!/bin/bash
# =============================================================================
# Platform — Cluster User Provisioning
# =============================================================================
# Creates an X.509 client certificate signed by the cluster CA, binds the
# appropriate RBAC role, and writes a ready-to-use kubeconfig file.
#
# Usage:
#   ./create-user.sh <username> <role> [--namespace <ns>]
#
# Roles:
#   platform-admin   Full cluster admin (ClusterRoleBinding)
#   developer        Deploy / manage workloads in a specific namespace
#   viewer           Read-only access across all namespaces
#
# Examples:
#   ./create-user.sh alice platform-admin
#   ./create-user.sh bob   developer --namespace team-payments
#   ./create-user.sh carol viewer
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
die()  { echo -e "${RED}[ERR ]${NC}  $*"; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────────
USERNAME="${1:-}"
ROLE="${2:-}"
NAMESPACE=""

shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -z "$USERNAME" ]] && die "Usage: $0 <username> <role> [--namespace <ns>]"
[[ -z "$ROLE"     ]] && die "Usage: $0 <username> <role> [--namespace <ns>]"

# Validate role
case "$ROLE" in
    platform-admin|developer|viewer) ;;
    *) die "Invalid role '$ROLE'. Choose: platform-admin | developer | viewer" ;;
esac

# developer role requires --namespace
if [[ "$ROLE" == "developer" && -z "$NAMESPACE" ]]; then
    die "Role 'developer' requires --namespace <ns>"
fi

CERT_DIR="certs/users"
KUBECONFIG_DIR="kubeconfigs"
CERT_DAYS=365
CLUSTER_NAME="platform"

mkdir -p "$CERT_DIR" "$KUBECONFIG_DIR"

# ── Check CA exists ───────────────────────────────────────────────────────────
[[ -f "certs/ca.crt" && -f "certs/ca.key" ]] || \
    die "Cluster CA not found. Run ./start-cluster.sh first."

# ── Generate user key + CSR ───────────────────────────────────────────────────
info "Generating key and CSR for '${USERNAME}'…"

openssl genrsa -out "${CERT_DIR}/${USERNAME}.key" 2048 2>/dev/null
openssl req -new \
    -key  "${CERT_DIR}/${USERNAME}.key" \
    -out  "${CERT_DIR}/${USERNAME}.csr" \
    -subj "/CN=${USERNAME}/O=${ROLE}" \
    2>/dev/null

# ── Sign with cluster CA ──────────────────────────────────────────────────────
# The Kubernetes API server reads the CN as the username and O as the group.
# Our RBAC ClusterRoles are bound to groups matching the role names.
info "Signing certificate (CN=${USERNAME}, O=${ROLE})…"

openssl x509 -req \
    -in   "${CERT_DIR}/${USERNAME}.csr" \
    -CA   certs/ca.crt -CAkey certs/ca.key \
    -CAcreateserial \
    -out  "${CERT_DIR}/${USERNAME}.crt" \
    -days "$CERT_DAYS" -sha256 \
    -extfile <(printf "basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n") \
    2>/dev/null

ok "Certificate valid for ${CERT_DAYS} days."

# ── RBAC binding ─────────────────────────────────────────────────────────────
info "Creating RBAC binding…"

case "$ROLE" in
    platform-admin)
        kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform:${USERNAME}:platform-admin
  labels:
    platform.io/managed-user: "${USERNAME}"
subjects:
  - kind: User
    name: "${USERNAME}"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: platform-admin
  apiGroup: rbac.authorization.k8s.io
EOF
        ;;

    developer)
        # Ensure namespace exists
        kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

        kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: platform:${USERNAME}:developer
  namespace: "${NAMESPACE}"
  labels:
    platform.io/managed-user: "${USERNAME}"
subjects:
  - kind: User
    name: "${USERNAME}"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: developer
  apiGroup: rbac.authorization.k8s.io
EOF
        ;;

    viewer)
        kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform:${USERNAME}:viewer
  labels:
    platform.io/managed-user: "${USERNAME}"
subjects:
  - kind: User
    name: "${USERNAME}"
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: viewer
  apiGroup: rbac.authorization.k8s.io
EOF
        ;;
esac

ok "RBAC binding created."

# ── Build kubeconfig ──────────────────────────────────────────────────────────
info "Building kubeconfig…"

# Extract cluster info from the current admin kubeconfig
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
USER_CERT=$(base64 -w0 < "${CERT_DIR}/${USERNAME}.crt")
USER_KEY=$(base64 -w0  < "${CERT_DIR}/${USERNAME}.key")

KUBECONFIG_PATH="${KUBECONFIG_DIR}/${USERNAME}.kubeconfig"

cat > "$KUBECONFIG_PATH" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${CLUSTER_SERVER}
      certificate-authority-data: ${CLUSTER_CA}
contexts:
  - name: ${USERNAME}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      user: ${USERNAME}
$([ -n "$NAMESPACE" ] && echo "      namespace: ${NAMESPACE}" || true)
current-context: ${USERNAME}@${CLUSTER_NAME}
users:
  - name: ${USERNAME}
    user:
      client-certificate-data: ${USER_CERT}
      client-key-data: ${USER_KEY}
EOF

ok "Kubeconfig written to ${KUBECONFIG_PATH}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  User:      ${USERNAME}"
echo "  Role:      ${ROLE}"
[[ -n "$NAMESPACE" ]] && echo "  Namespace: ${NAMESPACE}"
echo "  Kubeconfig: ${KUBECONFIG_PATH}"
echo ""
echo "  Share with the user:"
echo "    export KUBECONFIG=\$(pwd)/${KUBECONFIG_PATH}"
echo "    kubectl get pods"
echo ""
echo "  Certificate expires: $(date -d "+${CERT_DAYS} days" '+%Y-%m-%d' 2>/dev/null || date -v+${CERT_DAYS}d '+%Y-%m-%d')"
echo "  Re-run this script to renew."
echo ""
