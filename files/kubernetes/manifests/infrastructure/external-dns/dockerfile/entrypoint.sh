#!/bin/bash
set -e

echo "=== External-Unbound DNS Server ==="
echo "Configuration: /opt/unbound/etc/unbound/unbound.conf"
echo "Local-zones: /shared/local-zones/"
echo "RPZ: /shared/rpz/"
echo "Process: DNS-only (monitoring disabled)"
echo "DNSSEC: Disabled (trust anchor issues avoided)"

# 必要なディレクトリを作成（PVCマウント時に空の場合）
mkdir -p /shared/local-zones /shared/rpz
echo "📁 Ensured directories exist: /shared/local-zones, /shared/rpz"

# ローカルゾーン設定ファイルの確認
if [ -d "/shared/local-zones" ]; then
    ZONE_COUNT=$(find /shared/local-zones -name "*.conf" | wc -l)
    if [ "$ZONE_COUNT" -gt 0 ]; then
        echo "📋 Local-zone files detected: $ZONE_COUNT files"
        # 最初のファイルの統計情報表示（あれば）
        FIRST_FILE=$(find /shared/local-zones -name "*.conf" | head -1)
        if [ -f "$FIRST_FILE" ]; then
            DOMAIN_COUNT=$(grep -c "^local-zone:" "$FIRST_FILE" 2>/dev/null || echo "0")
            echo "📊 Blocked domains: $DOMAIN_COUNT"
        fi
    else
        echo "⚠️  Warning: No local-zone files found in /shared/local-zones/"
        echo "   CronJob will populate blocklists on next scheduled run (17:00 UTC daily)"
    fi
else
    echo "⚠️  Warning: /shared/local-zones directory not found (PVC not mounted)"
fi

# RPZファイルの確認
RPZ_COUNT=$(find /shared/rpz -name "*.txt" 2>/dev/null | wc -l)
if [ "$RPZ_COUNT" -gt 0 ]; then
    echo "📋 RPZ blocklist files detected: $RPZ_COUNT files"
else
    echo "⚠️  Warning: No RPZ files found in /shared/rpz/"
    echo "   CronJob will populate blocklists on next scheduled run (17:00 UTC daily)"
    echo "   DNS will work without blocklists until then"
fi

# DNSSEC無効化のため、trust anchor初期化をスキップ
echo "🔐 DNSSEC trust anchor: Disabled (configuration simplified)"

# 設定ファイル妥当性確認
echo "✅ Validating Unbound configuration..."
unbound-checkconf /opt/unbound/etc/unbound/unbound.conf

if [ $? -eq 0 ]; then
    echo "✅ Configuration validation successful"
else
    echo "❌ Configuration validation failed"
    exit 1
fi

# プロセス情報表示
echo "👤 Running as: $(whoami)"
echo "🔧 Process mode: Foreground (Docker optimized)"

echo ""
echo "🚀 Starting Unbound DNS server..."
echo "   Internal Port: 5353/tcp, 5353/udp"  
echo "   External Access: 192.168.11.101:53"
echo "   Log level: 1 (operational)"
echo "   Cache: msg=25MB, rrset=50MB"
echo "   Upstream: 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4"
echo ""

# Unboundをフォアグラウンドで実行
exec unbound -d -c /opt/unbound/etc/unbound/unbound.conf