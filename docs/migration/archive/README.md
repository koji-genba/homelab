# 移行記録アーカイブ

ここにある文書は**すべて完了済みの記録**である。現在の作業指示ではない。
更新しない。歴史的経緯、実測値、判断の根拠を後から辿るためだけに残す。

現在進行中の作業は[次セッションへの作業指示](../next-session.md)にある。

| 文書 | 内容 | 期間 |
| --- | --- | --- |
| [実装状況](implementation-status.md) | Phase 0〜4の実装・ローカル検証・実機反映の全記録。受入試験の結果、判明した実装バグ、Phase 3が明らかにしたProxmox権限の欠陥、DGX Spark用ストレージの反映まで | 2026-08-30〜2026-09-19 |
| [Phase 2A事前調査結果](phase2a-inventory.md) | application cutover前の読み取り専用調査。NFS writer、service IP所有権、IX2215実測、snapshot計画、ユーザー判断 | 2026-09-05 |

## ここから現役の文書へ移した知見

完了記録の中にあった、今後も使う手順は次へ移してある。アーカイブ側を参照しない。

| 知見 | 現在の所在 |
| --- | --- |
| Apps VMをdestroyする際のProxmox ACL再付与と403の診断 | [Apps VM復旧手順](../../operations/apps-vm-recovery.md) |
| IX2215のACLエントリを書き換える手順、`config.txt`の照合方法 | [IX2215 ACL stateful化 実施手順書](../../network/ix-acl-stateful-runbook.md) |
| `make ansible-apply`に要る`SSH_AUTH_SOCK`と`AGE_IDENTITY_FILE` | [アプリケーションのライフサイクル](../../operations/application-lifecycle.md)、[toolbox README](../../../files/tools/homelab-toolbox/README.md) |
| 現在のシステム状態、安全条件、rollback手順 | [次セッションへの作業指示](../next-session.md) |
