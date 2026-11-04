# ADR-0010: ai・archiveをtank-gen3 mirrorへ配置する

## 状態

採用。以下の決定・影響は採用時の記録。初回scrubと旧コピー削除の確認結果は2026-11-04の補足を参照する。

## 決定

Seagate ST24000DM001 24TB ×2のmirror `tank-gen3`へaiとarchiveを配置する。
[ADR-0006](0006-ai-dataset-single-export.md)の単一AI exportとclient mount先は維持し、
server側の配置を`tank-gen2/data/ai`から`tank-gen3/data/ai`へ変更する。
archiveは`tank-gen1/data/archive`から`tank-gen3/data/archive`へ変更する。

プロパティ・監視・四半期scrub・archiveの書き込み可と自動snapshot（日14・週8・月12、毎日04:30）は
[tank-gen3運用](../operations/tank-gen3.md)を正とする。スピンダウン・PUISは使わない。

## 影響

send/recvの初回転送中はwriterを維持し、切り替え時だけ停止して差分を転送する。
旧datasetはreadonly・非exportで検証完了まで残し、削除は別作業とする。
移行後のtank-gen1は、アーカイブの2つ目のコピーの置き場にする案（未決定）。

## 2026-10-31 変更: archiveを書き込み可と自動snapshotへ

当初はarchiveを通常`readonly=on`とし、追加・検証ごとに`@verified-YYYYMMDD`を
手動取得する決定だった。2026-10-31にユーザーがこの運用を変更し、通常も書き込み可能にして、
誤削除・誤上書き・ランサムウェアに備える世代を自動取得することを決定した。
配置先・pool構成は維持する。毎日の日次14世代と、月初の月次12世代、月初以外の月曜の週次8世代を保持する。
初期の`@to-gen3-*`と`@verified-20261031`は移行記録として残し、自動削除の対象にしない。
この補足は決定の変更記録であり、実機のreadonly解除・cron配置が完了したことを意味しない。

## 2026-11-04 補足: 初回scrubと旧コピー削除

2026-11-03 21:03〜11-04 05:09に移行後の初回scrubを実施し、5.21Tを8時間6分で確認した。
修復0B、エラー0。2026-11-04 22:19に、readonly・非exportで検証用に残していた
`tank-gen2/data/ai`と`tank-gen1/data/archive`をそれぞれの`@to-gen3-1`・`@to-gen3-2`とともに削除した。
`tank-gen3/data/ai`の移行用`@to-gen3-1`・`@to-gen3-2`も削除済み。
検証内容と削除後の容量は[tank-gen3運用](../operations/tank-gen3.md#旧コピー削除の実施記録2026-11-04)を参照する。

現行archiveの`@to-gen3-1`・`@to-gen3-2`・`@verified-20261031`は残している。
tank-gen1は`tank-gen1/data`だけが残るデータの無いpoolで、archiveの2つ目のコピーにする案は見送った。
使い道は未決定で、archiveの初期snapshotの見直しとともに[issue #186](https://github.com/koji-genba/homelab/issues/186)で扱う。
