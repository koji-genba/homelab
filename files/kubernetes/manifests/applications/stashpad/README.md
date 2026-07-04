# stashPad (staging / prod)

自宅メディアライブラリ [stashPad](https://github.com/koji-genba/stashPad) のk8sデプロイ設定。
CIは stashPad リポジトリの GitHub Actions(`.github/workflows/ci.yml`)、CDはこのリポジトリを
Flux が pull 型で反映する構成。stashPadリポジトリ・GHCRイメージともpublicなので、
`imagePullSecrets` は不要。

## 仕組み

- `main` へ push → GitHub Actions が `ghcr.io/koji-genba/stashpad` に `edge` / `main-<run_number>-<sha>` タグでpush
  → Flux の Image Update Automation が検知し `overlays/staging/kustomization.yaml` の `newTag` を自動で書き換えてcommit&push
  → Flux Kustomization(`stashpad-staging`)が反映 → **staging は完全自動**
- `v*.*.*` タグをpush → Actions が `<tag>` / `latest` タグでpush → **prodは自動反映されない**。昇格したい場合は
  `overlays/prod/kustomization.yaml` の `newTag` を手動で書き換えてこのリポジトリにcommit&pushする。

```text
stashPad repo                              homelab repo (このディレクトリ)
main push  → Actions → ghcr.io/koji-genba/stashpad:edge, main-<run>-<sha>
                                            ↓ (Flux ImageUpdateAutomationが自動書き換え)
                                            overlays/staging/kustomization.yaml (newTag)
                                            ↓ (Flux Kustomization stashpad-staging)
                                            → stashpad-staging namespace へ反映

v1.2.3 tag push → Actions → ghcr.io/koji-genba/stashpad:v1.2.3, latest
                                            ↓ (人が手動で書き換え)
                                            overlays/prod/kustomization.yaml (newTag: v1.2.3)
                                            ↓ (Flux Kustomization stashpad-prod)
                                            → stashpad-prod namespace へ反映
```

## ディレクトリ構成

- `base/` — Deployment / Service / PVC(data) / ConfigMap の共通定義
- `overlays/staging/`, `overlays/prod/` — namespace・読み取り専用メディア用の静的PV/PVC・Ingress・イメージタグ
- `flux/` — Flux の Kustomization(反映先) / ImageRepository・ImagePolicy・ImageUpdateAutomation(staging限定の自動更新)

## 手動で一度だけ必要な作業(再現手順)

クラスタ再構築時や別環境で作り直す場合のために、Gitに残せない手動作業をここにまとめる。

### 1. Flux のbootstrap(未実施ならここから)

```bash
# flux CLI インストール(未インストールの場合)
curl -s https://fluxcd.io/install.sh | sudo bash

# GitHubで repo スコープの Personal Access Token を発行し、環境変数に設定
export GITHUB_TOKEN=<PAT>

flux bootstrap github \
  --owner=koji-genba --repository=homelab --branch=main \
  --path=files/kubernetes/flux-system --personal
```

bootstrap後、`files/kubernetes/flux-system/kustomization.yaml` の `resources:` に以下を追記してcommit&pushする(このディレクトリのFluxリソースを反映対象に含めるため):

```yaml
resources:
  - gotk-components.yaml
  - gotk-sync.yaml
  - ../manifests/applications/stashpad/flux
```

### 2. DNS追加分の反映

`files/kubernetes/manifests/infrastructure/external-dns/dns/manual-config-configmap.yaml` に
`staging.stashpad.kojigenba-srv.com` / `prod.stashpad.kojigenba-srv.com` を追記済み。
このファイルはFluxの管理対象外(既存のexternal-dns運用のまま)なので、変更後は手動で反映する:

```bash
kubectl apply -k files/kubernetes/manifests/infrastructure/external-dns/
kubectl rollout restart deployment/external-unbound -n external-dns
```

## 未確定の設定

- `base/configmap.yaml` の `STASHPAD_LIBRARY_ROOTS`(`library-roots`)は仮に `/media` としている。
  実際のライブラリ構成(`/mnt/shared/koji-genba` 配下、評価フォルダ分けなど)が固まったら
  `/media/...` 配下の実パスのカンマ区切りに書き換えること。

## 動作確認

```bash
# Flux の状態
flux get sources git
flux get kustomizations
flux get images all

# staging
kubectl -n stashpad-staging rollout status deployment/stashpad
curl -I https://staging.stashpad.kojigenba-srv.com

# prod昇格
#  1) stashPad repo: git tag v0.1.0 && git push origin v0.1.0
#  2) このrepoの overlays/prod/kustomization.yaml の newTag を v0.1.0 に書き換えてcommit & push
kubectl -n stashpad-prod rollout status deployment/stashpad
curl -I https://prod.stashpad.kojigenba-srv.com
```
