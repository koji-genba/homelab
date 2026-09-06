# Kubernetes rollback用 状態スナップショット

- 取得日: 2026-09-05
- 取得時点: **Kubernetes VM（VMID 101/102/103）を`qm shutdown`で停止する直前**
- 目的: 停止後は`kubectl`が使えなくなるため、rollbackに必要な変更前後の値をここへ恒久保存する。
  [次セッションへの作業指示](next-session.md)が「変更前の完全なService定義JSONはscratchpadにのみ存在し、
  恒久保存されていない」と課題としていた点を解消するものである。

この文書は**記録専用**である。ここに書かれた値をrollback以外の目的で適用しない。
rollbackの実施順序は[次セッションへの作業指示のrollback手順](next-session.md)に従う。

## 取得時のクラスタ状態

| 項目 | 値 |
| --- | --- |
| node | `k8s-master01` `192.168.10.21` / `k8s-worker01` `192.168.10.22` / `k8s-worker02` `192.168.10.23`、いずれも`Ready` |
| version | v1.36.1、containerd 2.2.3、Ubuntu 24.04.4 |
| 稼働中Pod | flux-system 6件と`default/nfs-client-provisioner` 1件のみ。application workloadは0件 |

`nfs-client-provisioner`はdynamic PVのprovisionerであり、停止すると新規PVCを作れなくなる。
既存PVは`Retain`かつNFS上の実体をそのまま参照するため、rollback時の再起動で復旧する。

## Flux

| kind | namespace/name | suspend | path |
| --- | --- | --- | --- |
| Kustomization | `flux-system/flux-system` | `true` | `./files/kubernetes/flux-system` |
| Kustomization | `flux-system/sillytavern` | `true` | `./files/kubernetes/manifests/applications/sillytavern/overlays/prod` |
| Kustomization | `flux-system/stashpad-prod` | `true` | `./files/kubernetes/manifests/applications/stashpad/overlays/prod` |
| Kustomization | `flux-system/stashpad-staging` | `true` | `./files/kubernetes/manifests/applications/stashpad/overlays/staging` |
| GitRepository | `flux-system/flux-system` | 未設定 | `ssh://git@github.com/koji-genba/homelab` の`main` |
| CronJob | `external-dns/blocklist-updater` | `true` | `0 17 * * *` |

rollbackでは4つのKustomizationを`flux reconcile`ではなく`flux resume`で戻す。
`blocklist-updater` CronJobのresumeは、後述のRPZ問題を解消してから行う。

## Deployment replicas

cutoverで`0`にしたものが対象である。rollbackでは`--replicas=1`へ戻す。

| namespace | name | 現在のspec.replicas | 直近revision | rollback後 |
| --- | --- | --- | --- | --- |
| `external-dns` | `external-unbound` | 0 | 288 | 1（後述の手順に従うこと） |
| `ingress-nginx` | `ingress-nginx-controller` | 0 | 1 | 1 |
| `samba` | `samba` | 0 | 1 | 1 |
| `sillytavern` | `sillytavern` | 0 | 1 | 1 |
| `stashpad-prod` | `stashpad` | 0 | 4 | 1 |
| `stashpad-staging` | `stashpad` | 0 | 16 | 1 |
| `default` | `nfs-client-provisioner` | 1 | 2 | 1（cutoverで変更していない） |

## DaemonSet `metallb-system/metallb-speaker`

- 現在の`spec.template.spec.nodeSelector`

  ```json
  {"homelab.io/metallb":"disabled","kubernetes.io/os":"linux"}
  ```

- rollbackで戻す値

  ```json
  {"kubernetes.io/os":"linux"}
  ```

- 現在の稼働数は`desired=0 / current=0 / ready=0`である。

## Service 3件（`LoadBalancer` → `ClusterIP`へ変更済み）

rollbackでは`spec.type`を`LoadBalancer`へ戻す。`spec.loadBalancerIP`は固定済みのため、
MetalLBは同じIPを再割り当てする。`clusterIP`は既存値を保持しているのでtype変更だけでよい。

| Service | namespace | loadBalancerIP | clusterIP | port |
| --- | --- | --- | --- | --- |
| `ingress-nginx-controller` | `ingress-nginx` | `192.168.11.100` | `10.233.46.159` | 80/TCP → `http`、443/TCP → `https` |
| `external-unbound-dns` | `external-dns` | `192.168.11.101` | `10.233.58.19` | 53/UDP・53/TCP → `5353` |
| `samba-smb` | `samba` | `192.168.11.103` | `10.233.25.71` | 445/TCP → `445` |

`external-unbound-dns`だけがMetalLBのannotationを持つ。ほかの2件はannotationなしで
`spec.loadBalancerIP`のみを使っている。

### `ingress-nginx/ingress-nginx-controller`

```json
{
  "apiVersion": "v1",
  "kind": "Service",
  "metadata": {
    "annotations": {},
    "labels": {
      "app.kubernetes.io/component": "controller",
      "app.kubernetes.io/instance": "ingress-nginx",
      "app.kubernetes.io/name": "ingress-nginx",
      "app.kubernetes.io/part-of": "ingress-nginx",
      "app.kubernetes.io/version": "1.13.1"
    },
    "name": "ingress-nginx-controller",
    "namespace": "ingress-nginx"
  },
  "spec": {
    "clusterIP": "10.233.46.159",
    "clusterIPs": ["10.233.46.159"],
    "internalTrafficPolicy": "Cluster",
    "ipFamilies": ["IPv4"],
    "ipFamilyPolicy": "SingleStack",
    "loadBalancerIP": "192.168.11.100",
    "ports": [
      {"appProtocol": "http", "name": "http", "port": 80, "protocol": "TCP", "targetPort": "http"},
      {"appProtocol": "https", "name": "https", "port": 443, "protocol": "TCP", "targetPort": "https"}
    ],
    "selector": {
      "app.kubernetes.io/component": "controller",
      "app.kubernetes.io/instance": "ingress-nginx",
      "app.kubernetes.io/name": "ingress-nginx"
    },
    "sessionAffinity": "None",
    "type": "LoadBalancer"
  }
}
```

### `external-dns/external-unbound-dns`

```json
{
  "apiVersion": "v1",
  "kind": "Service",
  "metadata": {
    "annotations": {
      "metallb.universe.tf/loadBalancerIPs": "192.168.11.101",
      "service.kubernetes.io/load-balancer-class": "metallb.io/metallb"
    },
    "labels": {"app": "external-unbound", "component": "dns-service", "version": "v1.3"},
    "name": "external-unbound-dns",
    "namespace": "external-dns"
  },
  "spec": {
    "clusterIP": "10.233.58.19",
    "clusterIPs": ["10.233.58.19"],
    "internalTrafficPolicy": "Cluster",
    "ipFamilies": ["IPv4"],
    "ipFamilyPolicy": "SingleStack",
    "loadBalancerIP": "192.168.11.101",
    "ports": [
      {"name": "dns-udp", "port": 53, "protocol": "UDP", "targetPort": 5353},
      {"name": "dns-tcp", "port": 53, "protocol": "TCP", "targetPort": 5353}
    ],
    "selector": {"app": "external-unbound"},
    "sessionAffinity": "None",
    "type": "LoadBalancer"
  }
}
```

### `samba/samba-smb`

```json
{
  "apiVersion": "v1",
  "kind": "Service",
  "metadata": {
    "annotations": {},
    "labels": {
      "app.kubernetes.io/component": "file-sharing",
      "app.kubernetes.io/name": "samba"
    },
    "name": "samba-smb",
    "namespace": "samba"
  },
  "spec": {
    "clusterIP": "10.233.25.71",
    "clusterIPs": ["10.233.25.71"],
    "internalTrafficPolicy": "Cluster",
    "ipFamilies": ["IPv4"],
    "ipFamilyPolicy": "SingleStack",
    "loadBalancerIP": "192.168.11.103",
    "ports": [{"name": "smb", "port": 445, "protocol": "TCP", "targetPort": 445}],
    "selector": {"app.kubernetes.io/name": "samba"},
    "sessionAffinity": "None",
    "type": "LoadBalancer"
  }
}
```

## Unbound復旧手順の訂正（重要）

これまでの記録は「旧ReplicaSet `external-unbound-588bcf9d7c`（revision 129）が正常な世代であり、
新ReplicaSet `external-unbound-75dd79988f`（revision 288）は不正なRPZでCrashLoopする」としていた。
**この記述は誤りであり、そのままではrollbackを実行できない。** 停止直前の実機確認で次が判明した。

1. `external-unbound-588bcf9d7c`は**存在しない**。Deploymentの`revisionHistoryLimit`は`10`で、
   現存するReplicaSetはrevision 278〜288の11件だけである。revision 129はとうに回収されている。
2. 現存する11件のReplicaSetは**pod templateが完全に同一**である。差分は
   `kubectl.kubernetes.io/restartedAt` annotationと`pod-template-hash`だけで、
   template本体のhashは全件`edb261e79bf9d3d6`で一致する。imageも全件
   `ghcr.io/koji-genba/external-unbound:v1.8`である。
   つまり「正常な世代」と「不正な世代」というReplicaSet単位の区別は最初から存在しない。
3. CrashLoopの原因はReplicaSetではなく**PVC上のデータ**である。
   `/mnt/tank-gen2/data/k8s-volumes/external-dns-blocklist-data-pvc-8e7db6e1-d7e8-4b0d-8de2-75dfb391a07f/rpz/hagezi-tif.txt`
   は143 bytesしかなく、中身はRPZ zoneではなくGitHub側のエラー文である。

   ```text
   Package size exceeded the configured limit of 150 MB. Try https://github.com/hagezi/dns-blocklists/tree/<rev>/rpz/tif.txt instead.
   ```

   `blocklist-updater` CronJobのdownloaderがHTTPエラー本文をそのままファイルへ保存したため、
   Unboundがこのzoneのloadに失敗して起動できない。ほかの5つのRPZファイルは正常なサイズである
   （`hagezi-pro.txt` 12.6 MB ほか）。

**したがってrollback時のUnbound復旧は次の順序で行う。ReplicaSetを選び直す操作は不要である。**

1. NFS server（`192.168.10.11`）で`rpz/hagezi-tif.txt`を退避する。削除ではなく改名で退避する。
2. Unboundの設定が`hagezi-tif.txt`の不在を許容するかを確認する。許容しない場合は、
   同ディレクトリの正常なRPZファイルと同じ形式で、`$TTL`とSOAだけを持つ空zoneを置く。
3. `kubectl -n external-dns scale deploy external-unbound --replicas=1`でscale upする。
4. Podが`Running`になり、`192.168.11.101:53`が応答することを確認する。
5. `blocklist-updater` CronJobのresumeは、downloaderがHTTPエラーを検出して
   既存ファイルを上書きしないよう修正してから行う。修正前にresumeすると同じ事象を再発させる。

## NFS open state（停止直前のベースライン）

pve1の`/proc/fs/nfsd/clients/*/states`から取得した。停止後の差分比較に使う。

| client | ホスト | open件数 | write open |
| --- | --- | --- | --- |
| `192.168.10.42` | Apps VM | 20 | あり。stashPad prod/staging両方の`stashpad.db` `stashpad.db-wal` `stashpad.db-shm`にrw open + write delegation |
| `192.168.10.22` | k8s-worker01 | 6 | なし。`rpz/hagezi-pro.txt`へのread-only openのみ |
| `192.168.10.23` | k8s-worker02 | 4 | なし。同上 |
| `192.168.10.21` | k8s-master01 | 0 | NFS clientとしての接続なし |

worker 2台に残るopenは、すでに削除された旧Unbound Podが残したNFSv4のclient stateである。
Podは稼働していない（application Podは0件）。read-onlyのためdataへの影響はない。

## PVCとPV

`Retain`のためVM停止・削除でもdataは消えない。Phase 5の廃止判断まで削除しない。

| namespace | PVC | volume | 容量 | StorageClass |
| --- | --- | --- | --- | --- |
| `external-dns` | `blocklist-data` | `pvc-8e7db6e1-d7e8-4b0d-8de2-75dfb391a07f` | 100Mi | `nfs-k8s-volumes` |
| `samba` | `samba-archive-storage` | `samba-archive-pv` | 6Ti | `nfs-archive-static` |
| `samba` | `samba-shared-hdd-storage` | `samba-shared-hdd-pv` | 18Ti | `nfs-shared-hdd-static` |
| `samba` | `samba-shared-storage` | `samba-shared-pv` | 19Ti | `nfs-shared-static` |
| `sillytavern` | `sillytavern-data` | `pvc-85f01a24-9480-4341-a6ad-f44b17cbecaa` | 5Gi | `nfs-k8s-volumes` |
| `stashpad-prod` | `stashpad-data` | `pvc-c96b1813-be70-49ca-865f-989e77359a6b` | 5Gi | `nfs-k8s-volumes` |
| `stashpad-prod` | `stashpad-media` | `stashpad-media-pv-prod` | 1Ti | `nfs-media-static` |
| `stashpad-staging` | `stashpad-data` | `pvc-ecc8b17c-bd0a-47db-b169-248d5d98995b` | 5Gi | `nfs-k8s-volumes` |
| `stashpad-staging` | `stashpad-media` | `stashpad-media-pv-staging` | 1Ti | `nfs-media-static` |
