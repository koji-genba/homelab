#!/bin/bash

# OpenLDAP Kubernetes Deployment Script
# This script deploys OpenLDAP with Samba integration to Kubernetes

set -e

NAMESPACE="openldap"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== OpenLDAP Deployment Script ==="
echo "Namespace: $NAMESPACE"
echo ""

# クリーンアップオプション
if [ "$1" == "--clean" ]; then
  echo "⚠️  Clean mode: Deleting resources..."

  # Deploymentを先に削除（PVCのアンマウントを促進）
  echo "Deleting Deployments..."
  kubectl delete deployment -n $NAMESPACE --all --ignore-not-found=true 2>/dev/null || true
  sleep 3

  # Podを先に強制削除（PVCの削除を進めるため）
  echo "Deleting Pods..."
  kubectl delete pod -n $NAMESPACE --all --grace-period=0 --force 2>/dev/null || true
  sleep 5

  # PVC明示削除
  echo "Deleting PVCs..."
  kubectl delete pvc -n $NAMESPACE --all --ignore-not-found=true
  echo "Waiting for PVCs to be deleted..."
  sleep 10

  # Namespace削除
  echo "Deleting namespace..."
  kubectl delete namespace $NAMESPACE --ignore-not-found=true
  echo "Waiting for namespace deletion..."
  sleep 30

  # PVの削除（オプション）
  echo "Checking for orphaned PVs..."
  kubectl get pv | grep openldap | awk '{print $1}' | xargs -r kubectl delete pv 2>/dev/null || true

  echo "✓ Cleanup completed"
  echo ""
fi

# Function to wait for deployment
wait_deployment() {
    local deployment=$1
    local ns=$2
    local timeout=${3:-300}

    echo "Waiting for deployment $deployment to be ready (max ${timeout}s)..."
    kubectl rollout status deployment/$deployment -n $ns --timeout=${timeout}s
}

# Function to wait for pods
wait_pod() {
    local pod_selector=$1
    local ns=$2
    local timeout=${3:-300}

    echo "Waiting for pods with selector $pod_selector to be ready (max ${timeout}s)..."
    for i in $(seq 1 $timeout); do
        if kubectl get pods -n $ns -l $pod_selector -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
            echo "Pod is ready!"
            return 0
        fi
        if [ $((i % 10)) -eq 0 ]; then
            echo "Still waiting... ($i/$timeout)"
        fi
        sleep 1
    done

    echo "Timeout waiting for pod!"
    return 1
}

# Step 1: Create namespace
echo ""
echo "[Step 1/6] Creating namespace..."
kubectl apply -f namespace.yaml

# Wait for namespace to be created
sleep 2

# Check for required Secret
echo "Checking for required Secret..."
while ! kubectl get secret openldap-secrets -n $NAMESPACE >/dev/null 2>&1; do
  echo "⚠️  Secret 'openldap-secrets' not found in namespace '$NAMESPACE'"
  echo ""
  echo "Required actions:"
  echo "  1. Run: scripts/generate-all.sh"
  echo "  2. Apply: kubectl apply -f secret.yaml"
  echo ""
  echo "Press Enter after applying the secret to continue, or Ctrl+C to cancel..."
  read
done
echo "✓ Secret 'openldap-secrets' found"
echo ""

# Check for phpLDAPadmin ConfigMap
echo "Checking for phpLDAPadmin ConfigMap..."
while ! kubectl get configmap phpadmin-env -n $NAMESPACE >/dev/null 2>&1; do
  echo "⚠️  ConfigMap 'phpadmin-env' not found in namespace '$NAMESPACE'"
  echo ""
  echo "Required action:"
  echo "  Apply: kubectl apply -f phpldapadmin/configmap-phpadmin.yaml"
  echo ""
  echo "Press Enter after applying the ConfigMap to continue, or Ctrl+C to cancel..."
  read
done
echo "✓ ConfigMap 'phpadmin-env' found"
echo ""

# Step 2: Create PVC
echo ""
echo "[Step 2/6] Creating PVC..."
kubectl apply -f "$SCRIPT_DIR/openldap/pvc.yaml"

# Step 3: Create ConfigMap and bootstrap data
echo ""
echo "[Step 3/6] Creating ConfigMap and bootstrap data..."
kubectl apply -f "$SCRIPT_DIR/openldap/configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/openldap/bootstrap-configmap.yaml"
kubectl apply -f "$SCRIPT_DIR/openldap/bootstrap-update-configmap.yaml"

# Step 4: Create TLS Certificates (MUST be before Deployment to ensure Secret exists)
echo ""
echo "[Step 4/6] Creating certificates..."
kubectl apply -f "$SCRIPT_DIR/openldap/certificate.yaml"
kubectl apply -f "$SCRIPT_DIR/openldap/certificate-ldaps.yaml"

# Wait for certificates to be ready (cert-manager needs time to issue certs)
echo "Waiting for TLS certificates to be issued (max 120s)..."
for i in $(seq 1 120); do
    if kubectl get secret -n $NAMESPACE ldaps-kojigenba-srv-com-tls >/dev/null 2>&1; then
        echo "✓ TLS certificate Secret is ready!"
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        echo "  Still waiting... ($i/120)"
    fi
    sleep 1
done

# Step 5: Deploy OpenLDAP (now that certificates are ready)
echo ""
echo "[Step 5/6] Deploying OpenLDAP..."
kubectl apply -f "$SCRIPT_DIR/openldap/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/openldap/service-ldap.yaml"
kubectl apply -f "$SCRIPT_DIR/openldap/service-ldaps.yaml"

# Wait for OpenLDAP pod to be ready
echo ""
echo "Waiting for OpenLDAP pod to be ready (max 300s)..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=openldap \
  -n $NAMESPACE \
  --timeout=300s

echo "✓ OpenLDAP pod is ready"
echo ""

# Step 6: Run bootstrap job
echo ""
echo "[Step 6/6] Running bootstrap job..."
kubectl delete job openldap-bootstrap -n $NAMESPACE --ignore-not-found=true
sleep 5
kubectl apply -f "$SCRIPT_DIR/openldap/bootstrap-job.yaml"

# Wait for bootstrap job
echo ""
echo "Waiting for bootstrap job to complete (max 300s)..."
kubectl wait --for=condition=complete job/openldap-bootstrap \
  -n $NAMESPACE \
  --timeout=300s || {
    echo ""
    echo "ERROR: Bootstrap job failed or timed out"
    echo "Check logs with: kubectl logs -n $NAMESPACE job/openldap-bootstrap"
    exit 1
}

echo "✓ Bootstrap job completed successfully"
echo ""

# Deploy phpLDAPadmin (optional)
if [ -f "$SCRIPT_DIR/phpldapadmin/deployment-phpadmin.yaml" ]; then
  echo "Deploying phpLDAPadmin..."
  kubectl apply -f "$SCRIPT_DIR/phpldapadmin/deployment-phpadmin.yaml"
  kubectl apply -f "$SCRIPT_DIR/phpldapadmin/service-phpadmin.yaml"
  kubectl apply -f "$SCRIPT_DIR/ingress.yaml"
  echo "✓ phpLDAPadmin deployed"
else
  echo "Note: phpLDAPadmin deployment files not found (optional)"
fi

# Display deployment summary
echo ""
echo "=== OpenLDAP Deployment Summary ==="
kubectl get pods,svc,pvc,certificate -n $NAMESPACE

echo ""
echo "✓ OpenLDAP deployment completed successfully!"
echo ""
echo "Access information:"
echo "  - LDAP (internal): ldap://openldap-ldap.openldap.svc.cluster.local:389"
echo "  - LDAPS: ldaps://openldap-ldaps.openldap.svc.cluster.local:636"
echo "  - Base DN: dc=kojigenba-srv,dc=com"
echo "  - Admin DN: cn=admin,dc=kojigenba-srv,dc=com"
echo ""
echo "Test connection:"
echo "  kubectl exec -it -n $NAMESPACE deployment/openldap -- \\"
echo "    ldapsearch -x -H ldap://localhost:389 \\"
echo "    -D \"cn=admin,dc=kojigenba-srv,dc=com\" -W \\"
echo "    -b \"dc=kojigenba-srv,dc=com\" -LLL"
echo ""
