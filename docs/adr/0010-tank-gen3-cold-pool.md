# ADR-0010: ai・archiveをtank-gen3 mirrorへ配置する

## 状態

採用。構築・移行の適用は切り替え時。実施完了の記録ではない。

## 決定

Seagate ST24000DM001 24TB ×2のmirror `tank-gen3`へaiとarchiveを配置する。
[ADR-0006](0006-ai-dataset-single-export.md)の単一AI exportとclient mount先は維持し、
server側の配置を`tank-gen2/data/ai`から`tank-gen3/data/ai`へ変更する。
archiveは`tank-gen1/data/archive`から`tank-gen3/data/archive`へ変更する。

プロパティ・監視・四半期scrub・archiveのreadonlyとverified snapshotは
[tank-gen3運用](../operations/tank-gen3.md)を正とする。スピンダウン・PUISは使わない。

## 影響

send/recvの初回転送中はwriterを維持し、切り替え時だけ停止して差分を転送する。
旧datasetはreadonly・非exportで検証完了まで残し、削除は別作業とする。
移行後のtank-gen1は、アーカイブの2つ目のコピーの置き場にする案（未決定）。
