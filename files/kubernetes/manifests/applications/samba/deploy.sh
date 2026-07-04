#!/bin/bash

# Samba deployment script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="samba"
USERS_FILE="${SAMBA_USERS_FILE:-${SCRIPT_DIR}/config/users.json}"
SECRETS_FILE="${SAMBA_SECRETS_FILE:-${SCRIPT_DIR}/config/secrets.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required to read Samba secrets JSON"
    exit 1
fi

# Check if Samba secrets JSON is provided
if [ ! -f "$USERS_FILE" ]; then
    log_error "Samba users file not found: ${USERS_FILE}"
    exit 1
fi

if ! jq -e 'type == "object" and (.localSid | type == "string") and (.groups | type == "array") and (.users | type == "array")' "$USERS_FILE" >/dev/null; then
    log_error "Samba users file is invalid: ${USERS_FILE}"
    exit 1
fi

if [ ! -f "$SECRETS_FILE" ]; then
    log_error "Samba secrets file not found: ${SECRETS_FILE}"
    log_info "Copy config/secrets.json.template to config/secrets.json and fill in the password values"
    log_info "Or set SAMBA_SECRETS_FILE=/path/to/secrets.json"
    exit 1
fi

if ! jq -e 'type == "object" and length > 0 and all(to_entries[]; (.key | test("^[A-Za-z0-9._-]+$")) and (.value | type == "string") and (.value | length > 0))' "$SECRETS_FILE" >/dev/null; then
    log_error "Samba secrets file must be a non-empty JSON object of string values"
    exit 1
fi

MISSING_SECRET_KEYS="$(jq -r --slurpfile secrets "$SECRETS_FILE" '.users[]?.passwordSecretKey // empty | . as $key | select($secrets[0] | has($key) | not)' "$USERS_FILE")"
if [ -n "$MISSING_SECRET_KEYS" ]; then
    log_error "Missing password keys in ${SECRETS_FILE}:"
    echo "$MISSING_SECRET_KEYS" | sed 's/^/  - /'
    exit 1
fi

log_info "Deploying Samba to Kubernetes..."

# Create namespace
log_info "Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

# Create Samba user password secret
log_info "Creating Samba secrets..."
SECRET_ENV_FILE="$(mktemp)"
trap 'rm -f "${SECRET_ENV_FILE}"' EXIT
chmod 600 "${SECRET_ENV_FILE}"
jq -r 'to_entries[] | "\(.key)=\(.value)"' "$SECRETS_FILE" > "${SECRET_ENV_FILE}"

kubectl create secret generic samba-secrets \
    --namespace "${NAMESPACE}" \
    --from-env-file="${SECRET_ENV_FILE}" \
    --dry-run=client \
    -o yaml | kubectl apply -f -

# Apply ConfigMaps
log_info "Applying Samba configuration..."
kubectl apply -f "${SCRIPT_DIR}/configmap-smb.yaml"
kubectl create configmap samba-users \
    --namespace "${NAMESPACE}" \
    --from-file=users.json="${USERS_FILE}" \
    --dry-run=client \
    -o yaml | kubectl apply -f -

# Apply PV and PVC
log_info "Creating persistent volumes and claims..."
kubectl apply -f "${SCRIPT_DIR}/pv-shared.yaml"
kubectl apply -f "${SCRIPT_DIR}/pvc-shared.yaml"
kubectl apply -f "${SCRIPT_DIR}/pv-shared-hdd.yaml"
kubectl apply -f "${SCRIPT_DIR}/pvc-shared-hdd.yaml"
kubectl apply -f "${SCRIPT_DIR}/pv-archive.yaml"
kubectl apply -f "${SCRIPT_DIR}/pvc-archive.yaml"

# Apply Deployment
log_info "Deploying Samba pod..."
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"

# Apply Service
log_info "Creating Samba service..."
kubectl apply -f "${SCRIPT_DIR}/service.yaml"

log_info "Samba deployment completed!"
log_info "Waiting for pod to be ready..."
kubectl rollout status deployment/samba -n "${NAMESPACE}" --timeout=5m

log_info "Samba service is available at: smb://192.168.11.103"
log_info "To check service status: kubectl get svc -n ${NAMESPACE}"
log_info "To check pod logs: kubectl logs -f deployment/samba -n ${NAMESPACE}"
