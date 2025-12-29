# NFS Provisioner（動的ストレージプロビジョニング）

NFSサーバーを使用した動的PersistentVolume（PV）プロビジョニングのデプロイ手順です。

## 概要

- **NFS Server**: 192.168.10.11
- **Export Path**: /tank-gen2/data/k8s-volumes
- **StorageClass**: nfs-k8s-volumes（default）
- **Reclaim Policy**: Retain（削除時もデータ保持）
- **Namespace**: default

## 機能

- PersistentVolumeClaim（PVC）作成時に自動的にPVを作成
- NFSサーバー上に `<namespace>-<pvc-name>-<pv-name>` 形式のディレクトリを作成
- 複数のPodから同時アクセス可能（ReadWriteMany）

## 前提条件

- Kubernetesクラスタが構築済み
- NFSサーバー（192.168.10.11）が稼働中
- NFSエクスポート設定済み:
  ```
  /tank-gen2/data/k8s-volumes 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
  ```

## NFSサーバー設定確認

### Proxmox VE ホスト側

```bash
# NFSサーバーで確認
ssh root@192.168.10.11

# エクスポート設定確認
cat /etc/exports

# NFS サービス確認
systemctl status nfs-server

# エクスポート一覧
showmount -e localhost

# ディレクトリ確認
ls -la /tank-gen2/data/k8s-volumes/
```

## デプロイ手順

### 1. RBAC設定

```bash
cd files/kubernetes/manifests/storage/nfs-provisioner/

kubectl apply -f rbac.yaml
```

### 2. Deployment デプロイ

```bash
kubectl apply -f deployment.yaml
```

### 3. StorageClass作成

```bash
kubectl apply -f storageclass.yaml
```

### 4. 動作確認

```bash
# Pod確認
kubectl get pods -l app=nfs-client-provisioner

# StorageClass確認（defaultとして設定されているか）
kubectl get sc

# 期待される出力:
# NAME                        PROVISIONER                                      RECLAIMPOLICY   VOLUMEBINDINGMODE
# nfs-k8s-volumes (default)   k8s-sigs.io/nfs-subdir-external-provisioner     Retain          Immediate
```

## 使用方法

### 基本的なPVC作成

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
  namespace: my-namespace
spec:
  accessModes:
    - ReadWriteMany  # 複数Podから同時アクセス
  resources:
    requests:
      storage: 10Gi
  storageClassName: nfs-k8s-volumes
```

### デフォルトStorageClassを使用（storageClassNameを省略）

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: auto-provisioned-pvc
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  # storageClassName省略時はdefault（nfs-k8s-volumes）が使用される
```

### PodでPVCをマウント

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: app
    image: nginx:latest
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-pvc
```

### StatefulSetでの使用

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: web
spec:
  serviceName: "web"
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        volumeMounts:
        - name: data
          mountPath: /usr/share/nginx/html
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: nfs-k8s-volumes
      resources:
        requests:
          storage: 1Gi
```

## ストレージ管理

### PV/PVC確認

```bash
# PVC一覧
kubectl get pvc --all-namespaces

# PV一覧
kubectl get pv

# PV詳細（NFSパス確認）
kubectl describe pv <pv-name>
```

### NFSサーバー側で確認

```bash
# NFSサーバーにログイン
ssh root@192.168.10.11

# 作成されたボリューム確認
ls -la /tank-gen2/data/k8s-volumes/

# ディスク使用量確認
du -sh /tank-gen2/data/k8s-volumes/*
```

### PVC削除

Reclaim Policy が `Retain` のため、PVC削除後もPVとNFS上のデータは保持されます。

```bash
# PVC削除
kubectl delete pvc <pvc-name> -n <namespace>

# PVは Released状態になる
kubectl get pv

# 手動でPV削除（データは保持される）
kubectl delete pv <pv-name>

# NFSサーバー側でデータを手動削除（必要に応じて）
ssh root@192.168.10.11
rm -rf /tank-gen2/data/k8s-volumes/<namespace>-<pvc-name>-<pv-name>
```

## トラブルシューティング

### PVCがPendingのまま

```bash
# PVC状態確認
kubectl describe pvc <pvc-name> -n <namespace>

# NFS Provisioner ログ確認
kubectl logs -l app=nfs-client-provisioner --tail=100

# NFS Provisioner Pod状態
kubectl get pods -l app=nfs-client-provisioner
```

### NFSマウントエラー

```bash
# ワーカーノードでNFSマウントテスト
ssh ubuntu@192.168.10.22
sudo mount -t nfs 192.168.10.11:/tank-gen2/data/k8s-volumes /mnt
ls -la /mnt
sudo umount /mnt

# NFSサーバー側でエクスポート確認
ssh root@192.168.10.11
exportfs -v
showmount -e localhost
```

### Permission denied エラー

NFSエクスポートで`no_root_squash`が設定されているか確認:

```bash
# NFSサーバーで確認
cat /etc/exports | grep k8s-volumes

# 期待される設定:
# /tank-gen2/data/k8s-volumes 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)

# 設定変更後はエクスポート再読み込み
exportfs -ra
```

### Provisioner Podが起動しない

```bash
# Pod状態確認
kubectl describe pod -l app=nfs-client-provisioner

# RBAC確認
kubectl get sa nfs-client-provisioner
kubectl get clusterrole nfs-client-provisioner-runner
kubectl get clusterrolebinding run-nfs-client-provisioner
```

## ストレージクラスのカスタマイズ

### 異なるNFSパスを使用

新しいStorageClassを作成:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-archive
provisioner: k8s-sigs.io/nfs-subdir-external-provisioner
parameters:
  archiveOnDelete: "true"  # 削除時にアーカイブ
reclaimPolicy: Delete      # 削除時にPVも削除
volumeBindingMode: Immediate
```

対応するDeploymentも追加作成が必要です（異なるNFSパス用）。

### アクセスモード

- **ReadWriteOnce (RWO)**: 単一ノードから読み書き
- **ReadWriteMany (RWX)**: 複数ノードから読み書き（NFSはRWX対応）
- **ReadOnlyMany (ROX)**: 複数ノードから読み取り専用

## アンインストール

```bash
# 注意: PVC/PVが存在する場合は先に削除
kubectl get pvc --all-namespaces

# StorageClass削除
kubectl delete -f storageclass.yaml

# Deployment削除
kubectl delete -f deployment.yaml

# RBAC削除
kubectl delete -f rbac.yaml
```

## 関連ドキュメント

- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [NFS Subdir External Provisioner](https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner)
- [プロジェクトルートREADME](../../../../../README.md)
