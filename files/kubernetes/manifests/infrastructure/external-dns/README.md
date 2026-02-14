# External DNS（Unbound DNSサーバー）

イントラネット向けDNSサーバー（Unbound）とHageziブロックリスト統合のデプロイ手順です。

## 概要

- **DNSサーバー**: Unbound
- **ブロックリスト**: hagezi/dns-blocklists (RPZ形式、6層保護)
- **LoadBalancer IP**: 192.168.11.101（MetalLBで固定割り当て）
- **Namespace**: external-dns
- **更新頻度**: 毎日17:00 UTC (翌日2:00 JST)にブロックリスト自動更新

## 機能

- 再帰的DNSリゾルバ
- RPZ（Response Policy Zone）による多層ブロック（Pro/TIF/DoH-Bypass/DynDNS/Badware/URLShortener）
- 広告/トラッカー/マルウェアドメインブロック（多層保護）
- カスタムDNSレコード対応
- 手動ブロックリスト/ホワイトリスト機能
- キャッシュ最適化

## ディレクトリ構造

```
external-dns/
├── README.md                      # このファイル
├── kustomization.yaml             # Kustomize設定
├── dns/                           # DNS本体（Unbound）
│   ├── deployment.yaml            # Unboundデプロイメント
│   ├── service.yaml               # LoadBalancerサービス
│   ├── configmap.yaml             # Unbound設定
│   └── manual-config-configmap.yaml  # 手動DNS設定
├── blocklist/                     # ブロックリスト自動更新
│   ├── pvc.yaml                   # ブロックリストデータ用PVC
│   ├── cronjob.yaml               # 自動更新CronJob
│   └── script-configmap.yaml      # ダウンロードスクリプト
└── dockerfile/                    # カスタムイメージビルド用
    ├── Dockerfile
    └── entrypoint.sh
```

## 前提条件

- Kubernetesクラスタが構築済み
- MetalLBがデプロイ済み
- NFSストレージクラス（`nfs-k8s-volumes`）が利用可能
- Dockerイメージビルド環境（カスタムイメージ使用時）

## デプロイ手順

### 1. カスタムイメージビルド（オプション）

公開イメージを使用する場合はスキップ可能です。

```bash
cd files/kubernetes/manifests/infrastructure/external-dns/dockerfile/

# イメージビルド（バージョンタグは適宜変更）
docker build -t ghcr.io/koji-genba/external-unbound:<version> .

# レジストリにプッシュ
docker push ghcr.io/koji-genba/external-unbound:<version>
```

### 2. 一括デプロイ（推奨）

Kustomize を使って全リソースを一括デプロイ：

```bash
cd files/kubernetes/manifests/infrastructure/external-dns/

# すべてのリソースをデプロイ
kubectl apply -k .
```

### 3. 個別デプロイ（詳細制御が必要な場合）

```bash
cd files/kubernetes/manifests/infrastructure/external-dns/

# DNS本体
kubectl apply -f dns/configmap.yaml
kubectl apply -f dns/manual-config-configmap.yaml
kubectl apply -f dns/deployment.yaml
kubectl apply -f dns/service.yaml

# ブロックリスト自動更新
kubectl apply -f blocklist/pvc.yaml
kubectl apply -f blocklist/script-configmap.yaml
kubectl apply -f blocklist/cronjob.yaml
```

### 4. 動作確認

```bash
# Pod確認
kubectl get pods -n external-dns

# Service確認（LoadBalancer IP取得）
kubectl get svc -n external-dns

# ログ確認
kubectl logs -n external-dns -l app=external-unbound --tail=100

# DNS IP取得
export DNS_IP=$(kubectl get svc -n external-dns external-unbound-dns \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "DNS Server IP: $DNS_IP"
```

## DNSクエリテスト

### 通常のDNSクエリ

```bash
# DNS IP取得（固定IP: 192.168.11.101）
DNS_IP=$(kubectl get svc -n external-dns external-unbound-dns -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# クエリテスト
kubectl run -it --rm dns-test --image=busybox --restart=Never -- \
  nslookup example.com $DNS_IP
```

### ブロックリスト動作確認

ブロックされるべきドメインをクエリ（例: 広告ドメイン）:

```bash
kubectl run -it --rm dns-test --image=busybox --restart=Never -- \
  nslookup ads.example.com $DNS_IP

# ブロックされた場合、0.0.0.0 または NXDOMAINが返される
```

### カスタムゾーンテスト

```bash
# カスタムゾーンで定義したドメイン
kubectl run -it --rm dns-test --image=busybox --restart=Never -- \
  nslookup custom.local $DNS_IP
```

## カスタムDNSレコード設定

### dns/manual-config-configmap.yaml 編集

`external-unbound-manual-config` ConfigMapには3つの設定ファイルがあります：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: external-unbound-manual-config
  namespace: external-dns
data:
  # カスタムDNSレコード
  manual-dns-records.txt: |
    local-data: "server.internal.example.com. A 192.168.10.100"
    local-data: "db.internal.example.com. A 192.168.10.101"

  # 追加ブロック対象ドメイン（RPZに統合）
  manual-blocklist.txt: |
    suspicious-ads.example.com
    tracking.badsite.com

  # ブロック除外ドメイン（ホワイトリスト）
  manual-whitelist.txt: |
    t.co
    tailscale.com
```

適用:

```bash
kubectl apply -f dns/manual-config-configmap.yaml

# ブロックリスト自動更新を手動実行（手動設定を反映）
kubectl create job -n external-dns --from=cronjob/blocklist-updater manual-update-$(date +%s)
```

## ブロックリスト管理

### RPZ自動更新の仕組み

このシステムは**PVC + CronJob方式**でブロックリストを更新します：

1. CronJobが毎日17:00 UTC (翌日2:00 JST)に実行
2. initContainerが最新のRPZファイル6つをPVCにダウンロード
3. メインコンテナがDeploymentをrollout restart
4. 新しいPodが起動し、PVC上の最新ブロックリストを読み込む

**PVC を使用する利点:**
- ブロックリストがPod再起動後も永続化
- 初回起動時にダウンロード不要で高速起動
- ネットワーク障害時でも既存データで起動可能

### 手動更新

```bash
# CronJobを手動実行
kubectl create job -n external-dns --from=cronjob/blocklist-updater manual-update-$(date +%s)

# ログ確認
kubectl logs -n external-dns -l job-name=manual-update-<timestamp> -c blocklist-downloader
kubectl logs -n external-dns -l job-name=manual-update-<timestamp> -c updater
```

### 使用中のRPZブロックリスト

`blocklist/script-configmap.yaml` で以下の6つのRPZリストをダウンロード：

- **Hagezi Pro Multi**: 基本保護（464K エントリ）
- **Hagezi TIF Full**: セキュリティ強化（755K エントリ）
- **DoH/VPN/Proxy Bypass**: DNS迂回防止（14K エントリ）
- **Dynamic DNS**: 動的DNS悪用対策（3K エントリ）
- **Badware Hoster**: 悪質ホスティング対策（4K エントリ）
- **URL Shortener**: 短縮URL対策（6K エントリ）

**合計**: 約167万ドメインをブロック

### 現在のブロックリスト確認

```bash
# RPZファイル確認
kubectl exec -n external-dns deployment/external-unbound -- \
  ls -lh /shared/rpz/

# エントリ数確認（各RPZファイル）
kubectl exec -n external-dns deployment/external-unbound -- \
  sh -c 'for f in /shared/rpz/*.txt; do echo "$f: $(grep -c "CNAME \." $f)"; done'

# initContainerログで統計確認
kubectl logs -n external-dns -l app=external-unbound -c blocklist-downloader
```

## パフォーマンス調整

### キャッシュ設定

[dns/configmap.yaml](dns/configmap.yaml) で調整:

```yaml
# キャッシュサイズ
msg-cache-size: 25m
rrset-cache-size: 50m

# TTL設定
cache-min-ttl: 300      # 最小5分
cache-max-ttl: 86400    # 最大1日

# プリフェッチ
prefetch: no
prefetch-key: no
```

### スレッド数

```yaml
# CPUコア数に応じて調整
num-threads: 2
```

## トラブルシューティング

### DNSクエリがタイムアウト

```bash
# Pod状態確認
kubectl get pods -n external-dns

# ログ確認
kubectl logs -n external-dns -l app=external-unbound --tail=100

# Service確認
kubectl describe svc external-unbound-dns -n external-dns

# LoadBalancer IP確認（192.168.11.101が割り当てられているか）
kubectl get svc -n external-dns
```

### ブロックリストが更新されない

```bash
# CronJob確認
kubectl get cronjob -n external-dns

# 最近のJob確認
kubectl get jobs -n external-dns

# Job ログ確認（Pod削除ログ）
kubectl logs -n external-dns -l job-name=blocklist-updater-<timestamp>

# 手動更新テスト（Pod削除→再作成）
kubectl create job -n external-dns --from=cronjob/blocklist-updater test-update

# initContainerログ確認（RPZダウンロード状況）
kubectl logs -n external-dns -l app=external-unbound -c blocklist-downloader
```

### カスタムDNSレコードが機能しない

```bash
# ConfigMap確認
kubectl get configmap external-unbound-manual-config -n external-dns -o yaml

# Unbound設定確認
kubectl exec -n external-dns deployment/external-unbound -- \
  unbound-checkconf /opt/unbound/etc/unbound/unbound.conf

# Pod再起動（手動設定反映）
kubectl rollout restart deployment/external-unbound -n external-dns

# local-zonesファイル確認
kubectl exec -n external-dns deployment/external-unbound -- \
  ls -la /shared/local-zones/
```

### RPZブロックが機能しない

```bash
# RPZファイル存在確認
kubectl exec -n external-dns deployment/external-unbound -- \
  ls -lh /shared/rpz/

# RPZエントリ数確認
kubectl exec -n external-dns deployment/external-unbound -- \
  sh -c 'for f in /shared/rpz/*.txt; do echo "$f: $(wc -l < $f) lines"; done'

# Unboundログでエラー確認
kubectl logs -n external-dns -l app=external-unbound | grep -i rpz

# テストクエリ（ブロックされるべきドメイン）
kubectl exec -n external-dns deployment/external-unbound -- \
  dig @127.0.0.1 -p 5353 doubleclick.net +short
```

## クライアント設定

### Linux/macOS

```bash
# /etc/resolv.conf 編集（一時的）
sudo bash -c 'echo "nameserver <DNS_IP>" > /etc/resolv.conf'

# systemd-resolved（Ubuntu等）
sudo vim /etc/systemd/resolved.conf
# [Resolve]
# DNS=<DNS_IP>
sudo systemctl restart systemd-resolved
```

### Windows

```powershell
# ネットワークアダプターのDNS設定を変更
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses "<DNS_IP>"
```

## アンインストール

### 一括削除（推奨）

```bash
kubectl delete -k .
```

### 個別削除

```bash
# ブロックリスト自動更新
kubectl delete -f blocklist/cronjob.yaml
kubectl delete -f blocklist/script-configmap.yaml
kubectl delete -f blocklist/pvc.yaml

# DNS本体
kubectl delete -f dns/service.yaml
kubectl delete -f dns/deployment.yaml
kubectl delete -f dns/manual-config-configmap.yaml
kubectl delete -f dns/configmap.yaml

# Namespace削除（全リソース削除）
kubectl delete namespace external-dns
```

## 関連ドキュメント

- [Unbound公式ドキュメント](https://nlnetlabs.nl/documentation/unbound/)
- [Hagezi DNS Blocklists](https://github.com/hagezi/dns-blocklists)
- [プロジェクトルートREADME](../../../../../README.md)
