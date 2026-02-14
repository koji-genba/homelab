#!/bin/bash
set -e
echo "=== External-Unbound Blocklist Updater ==="
echo "🕒 Update started at: $(date)"
echo ""

# Deployment が存在するか確認（初期化時は未デプロイの場合がある）
if ! kubectl get deployment external-unbound -n external-dns >/dev/null 2>&1; then
  echo "⚠️  Deployment external-unbound not found, skipping restart"
  echo "   (This is expected during initial setup)"
  echo "✅ Blocklist data has been written to PVC"
  exit 0
fi

# 現在のPod情報取得
echo "📋 Current pod status:"
kubectl get pods -n external-dns -l app=external-unbound -o wide
echo ""

# Rollout restart で Pod 再起動
echo "🔄 Triggering rollout restart..."
kubectl rollout restart deployment/external-unbound -n external-dns

echo "⏳ Waiting for rollout to complete..."
kubectl rollout status deployment/external-unbound -n external-dns --timeout=300s

# 新Pod情報取得
sleep 5
NEW_POD=$(kubectl get pods -n external-dns -l app=external-unbound -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "unknown")
echo ""
echo "🎉 Rollout completed! New pod: $NEW_POD"
kubectl get pods -n external-dns -l app=external-unbound -o wide
echo ""

# DNS動作確認
echo "🔍 Verifying DNS functionality:"
if kubectl exec -n external-dns "$NEW_POD" -- dig @127.0.0.1 -p 5353 google.com +short +time=5 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" >/dev/null 2>&1; then
  echo "   ✅ DNS resolution: Working"
else
  echo "   ❌ DNS resolution: Failed"
  exit 1
fi

# ブロック機能確認
if kubectl exec -n external-dns "$NEW_POD" -- dig @127.0.0.1 -p 5353 doubleclick.net +short +time=5 2>/dev/null | grep -E "(^$|NXDOMAIN|0\.0\.0\.0)" >/dev/null; then
  echo "   ✅ Ad blocking: Working"
else
  echo "   ⚠️  Ad blocking: Different response (may be normal)"
fi

echo ""
echo "🕒 Completed at: $(date)"
echo "✅ Blocklist update completed successfully"
