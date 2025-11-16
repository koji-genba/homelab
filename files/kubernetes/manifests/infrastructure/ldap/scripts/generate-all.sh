#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== OpenLDAP Configuration Generator ==="
echo ""
echo "This script generates all necessary configuration files from JSON definitions."
echo "You will be prompted to enter LDAP admin passwords interactively."
echo ""

# ステップ1: Bootstrap LDIF生成
echo "=========================================="
echo "Step 1/3: Generating bootstrap ConfigMap..."
echo "=========================================="
"$SCRIPT_DIR/generate-bootstrap-ldif.sh"
echo ""

# ステップ2: Bootstrap Update LDIF生成
echo "=========================================="
echo "Step 2/3: Generating bootstrap update ConfigMap..."
echo "=========================================="
"$SCRIPT_DIR/generate-bootstrap-update.sh"
echo ""

# ステップ3: Secrets生成（統合版）
echo "=========================================="
echo "Step 3/3: Generating secrets (LDAP admin + all users)..."
echo "=========================================="
"$SCRIPT_DIR/generate-user-secrets.sh"
echo ""

echo "=========================================="
echo "✓ All configuration files generated successfully!"
echo "=========================================="
echo ""
echo "Generated files:"
echo "  - ../openldap/bootstrap-configmap.yaml (LDAP entries)"
echo "  - ../openldap/bootstrap-update-configmap.yaml (Group memberships)"
echo "  - ../secret.yaml (All passwords and hashes)"
echo ""
echo "Next steps to apply changes:"
echo "  1. Restrict permissions: chmod 600 ../secret.yaml"
echo "  2. kubectl apply -f ../secret.yaml"
echo "  3. kubectl apply -f ../openldap/bootstrap-configmap.yaml"
echo "  4. kubectl apply -f ../openldap/bootstrap-update-configmap.yaml"
echo "  5. kubectl delete job openldap-bootstrap -n openldap (if exists)"
echo "  6. kubectl apply -f ../openldap/bootstrap-job.yaml"
echo "  7. kubectl wait --for=condition=complete --timeout=120s job/openldap-bootstrap -n openldap"
echo ""
