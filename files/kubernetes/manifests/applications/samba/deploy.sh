#!/bin/bash

# Samba deployment script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="samba"
ADMIN_PASSWORD="${SAMBA_ADMIN_PASSWORD:-}"

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

# Check if admin password is provided
if [ -z "$ADMIN_PASSWORD" ]; then
    log_error "SAMBA_ADMIN_PASSWORD environment variable is not set"
    log_info "Usage: SAMBA_ADMIN_PASSWORD=<password> ./deploy.sh"
    exit 1
fi

log_info "Deploying Samba to Kubernetes..."

# Create namespace
log_info "Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

# Create secrets from template
log_info "Creating Samba secrets..."
sed "s|\${ADMIN_PASSWORD}|${ADMIN_PASSWORD}|g" \
    "${SCRIPT_DIR}/secret.yaml.template" | kubectl apply -f -

# Apply ConfigMap
log_info "Applying Samba configuration..."
kubectl apply -f "${SCRIPT_DIR}/configmap-smb.yaml"

# Apply PVC
log_info "Creating persistent volume claim..."
kubectl apply -f "${SCRIPT_DIR}/pvc-shared.yaml"

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
