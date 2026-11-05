# ADR-0014: Hermes の受け渡し共有を Runner に NFS で渡す

- 日付: 2026-11-05
- 状態: 採用、repo 実装。実機反映は未実施、実機での受入は未検証
- 背景と決定: [issue #194](https://github.com/koji-genba/homelab/issues/194)
- 変更する前提: [ADR-0008](0008-hermes-agent-hindsight-vms.md) の Runner の LAN 宛新規接続遮断

## 決定と理由

Windows・Android の SMB と Hermes の間で大きなファイルを双方向に渡すため、
専用 dataset `tank-gen1/data/hermes` を作る。Runner は NFS 4.1 で
`/srv/agent-work/share` に直接 mount する（案 A）。Runner の output に、LAN 遮断より前の
`192.168.10.11:2049/tcp` の例外を一つだけ追加する。宛先全体の許可は使わない。
Agent の firewall 描画は変えず、ADR-0008 の原文も維持する。

Agent を仲介に定期同期する案 B は採らない。issue #194 のとおり、書き込み途中のファイル、
削除の伝播、同名ファイルの衝突を扱う手間と取りこぼしがあり、大きなファイルを
150GB の Runner ディスクへ丸ごと複製する負担もある。Discord 添付と MEDIA は小さいものに残す。

`inbox/` はユーザーから Hermes へ、`outbox/` は Hermes からユーザーへの約束とする。
両者とも両方を読み書きできる。quota は 2T、スナップショット・バックアップ・自動削除は無し。
DGX や scratch へ公開範囲を広げない。

## リスクと緩和策

- Runner の全プロセスから pve1 の nfsd に届く。nftables は export path を区別しないため、
  nfsd の脆弱性や将来の export 誤設定のリスクが増える。例外は TCP 2049 だけとし、
  22・111 等や他の LAN 宛ては引き続き遮断する。
- 専用 dataset を Apps `.101/32` と Runner `.105/32` にだけ export する。
  **例外を開ける前に** ai の `/24` export を `.101/32`・`.51/32`・`.52/32` に絞る。
  この絞り込みは未実施であり、反映時に `exportfs -v` で確認する。
  `all_squash,anonuid=10002,anongid=10004` により root も同じ共有利用者へ写す。
  export の既定 `secure` を維持し、非 root が高位送信元ポートで直接 NFS を話すことを拒否する。
  通常の非特権ユーザーは root が mount した kernel NFS 経由で利用する。
  `secure` は暗号化や利用者認証ではなく、root 侵害への防御でもない。
- 共有の内容はインターネットへ出得る。Runner の公開インターネットへの送信は残り、
  MEDIA によるユーザーへの配送もある。機密や唯一のコピーを置かず、README と skill で明示する。
  skill のアップロード禁止は行動指示であり、network による持ち出し防止ではない。
- NFS が止まると hard mount の Runner コマンドは待ち得る。automount と nofail は
  起動依存を緩和するだけで、I/O の待機を解消しない。Ansible はアクセスで mount させ、
  source・fstype・marker を検査して失敗を隠さない。下地は `root:root 0555`、
  backup の tar は `./share` を除外し、`--one-file-system` も付ける。
- Apps の共通 mount guard に共有を加えるため、共有障害は全 project の起動を止め得る。
  障害時の writer 停止・client 側切り離し・server 側整理を運用手順に定義する。

## 反映と受入

pve1 の ai 絞り込みと新 export → Agent/Runner apply → Apps reconcile pause と branch apply
→ main merge → reconcile 再開 → SMB と Hermes の受入の順。
新 skill の初回配置で Hermes と CDP tunnel が再作成されるため、会話中を避ける。
具体的な契約、操作、未検証事項は [Hermes 共有運用](../operations/hermes-share.md) を正とする。
