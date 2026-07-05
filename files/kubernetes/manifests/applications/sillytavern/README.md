# SillyTavern (prod)

LLM チャットフロントエンド [SillyTavern](https://github.com/SillyTavern/SillyTavern) のk8sデプロイ設定。
公式の public GHCR イメージ `ghcr.io/sillytavern/sillytavern:1.18.0` を固定して使うため、
`imagePullSecrets` は不要。サードパーティイメージなので Flux Image Update Automation は使わず、
更新時は `overlays/prod/kustomization.yaml` の `newTag` を手動で書き換える。

## 仕組み

- このリポジトリの `main` へ push → Flux が `files/kubernetes/flux-system` を pull
  → `../manifests/applications/sillytavern/flux` 経由で Flux Kustomization(`sillytavern`)が反映
  → `sillytavern` namespace へ Deployment / Service / PVC / Ingress を作成する。
- Ingress は `sillytavern.kojigenba-srv.com`、TLS Secret は cert-manager が
  `letsencrypt-prod` ClusterIssuer で `sillytavern-tls` として発行する。
- データは PVC `sillytavern-data` に保存し、コンテナ内の `/home/node/app/data` へマウントする。
- Basic 認証のユーザー名・パスワードは Git に置かず、Secret `sillytavern-basic-auth` から
  `SILLYTAVERN_BASICAUTHUSER_USERNAME` / `SILLYTAVERN_BASICAUTHUSER_PASSWORD` として渡す。
- SillyTavern 1.18.0 は `SILLYTAVERN_` 環境変数で `config.yaml` の値を上書きできるため、
  `listen: true` / `whitelistMode: false` / `basicAuthMode: true` も env で設定している。
  Basic 認証有効時の HTTP probe は 401 になり得るため、readiness / liveness は `tcpSocket` を使う。

## ディレクトリ構成

- `base/` — Deployment / Service / PVC(data) の共通定義と、適用しない Secret テンプレート
- `overlays/prod/` — namespace・Ingress・イメージタグ固定
- `flux/` — Flux の Kustomization(反映先)

## 手動で一度だけ必要な作業(再現手順)

クラスタ再構築時や別環境で作り直す場合のために、Gitに残せない手動作業をここにまとめる。

### 1. Basic 認証 Secret 作成

`base/secret.yaml.template` は雛形で、kustomize からは適用しない。
実体は次のように手動で作成する:

```bash
kubectl create namespace sillytavern --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sillytavern create secret generic sillytavern-basic-auth \
  --from-literal=username=<user> --from-literal=password=<pass> \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 2. DNS追加分の反映

`files/kubernetes/manifests/infrastructure/external-dns/dns/manual-config-configmap.yaml` に
`sillytavern.kojigenba-srv.com` を追記済み。
このファイルはFluxの管理対象外(既存のexternal-dns運用のまま)なので、変更後は手動で反映する:
`external-unbound-manual-config` ConfigMap は external-unbound Deployment にはマウントされておらず、
CronJob `blocklist-updater` の initContainer (`blocklist-downloader.sh`) だけが読み込む。
この initContainer が `/manual-config/manual-dns-records.txt` から PVC 上の
`/shared/local-zones/manual-dns-records.conf` を再生成し、unbound は起動時に
`/shared/local-zones/*.conf` を include するだけなので、rollout restart だけでは古い conf を読み直すだけになる。
ConfigMap 更新後は CronJob を手動実行し、conf の再生成と external-unbound の再起動をまとめて行う。

```bash
# 1) 更新した ConfigMap をクラスタへ反映
kubectl apply -k files/kubernetes/manifests/infrastructure/external-dns/

# 2) blocklist-updater CronJob を手動実行(initContainerが local-zones を再生成し、後続コンテナが external-unbound を rollout restart する)
kubectl -n external-dns create job --from=cronjob/blocklist-updater manual-dns-$(date +%s)

# 3) 進行確認(このJobはHageziブロックリスト全体も再DLするため数分かかる)
kubectl -n external-dns get jobs
kubectl -n external-dns logs -f job/<上で作成したjob名>
```

補足: この CronJob は実行ごとに Hagezi ブロックリスト全体を再ダウンロードするため重く、数分から15分程度かかることがあるが、時間がかかること自体はエラーではない。

### 3. Flux 反映

`files/kubernetes/flux-system/kustomization.yaml` の `resources:` に
`../manifests/applications/sillytavern/flux` を追記済み。
このリポジトリを commit & push すると Flux が pull して反映する。

## 動作確認

```bash
# ローカル(クラスタ到達不要)
kubectl kustomize files/kubernetes/manifests/applications/sillytavern/overlays/prod

# 反映後(クラスタ到達環境で実施)
flux get kustomizations | grep sillytavern
kubectl -n sillytavern rollout status deployment/sillytavern
kubectl -n sillytavern get pod,svc,ingress,pvc
kubectl -n sillytavern logs deploy/sillytavern | head
curl -I https://sillytavern.kojigenba-srv.com
```
