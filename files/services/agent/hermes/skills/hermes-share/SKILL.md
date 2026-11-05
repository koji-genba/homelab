---
name: hermes-share
description: SMB経由でユーザーと大きなファイルを受け渡す。共有のinboxを読み、outboxに成果物を置く。
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [files, share, inbox, outbox]
---

# Hermes Share

Runner の terminal（SSH backend）から `/srv/agent-work/share` を使う。
Windows・Android の SMB と同じ共有で、Agent コンテナのローカルパスではない。

## 手順

1. 操作前に terminal で `cat /srv/agent-work/share/.homelab-export` を実行する。
   このアクセスが automount を起動する。値が `hermes` であることと、
   `findmnt -rn -t nfs4 -M /srv/agent-work/share -o SOURCE` が
   `192.168.10.11:/mnt/tank-gen1/data/hermes` であることを確認する。
   share が空、目印が無い・異なる、接続先が異なる、読み取りが失敗・待ち続ける場合は
   書き込まずユーザーに伝える。ローカルに代替の share や目印を作らない。
2. `inbox/` はユーザーが置いたファイル。読んだり加工したりしてよいが、原本を消さない。
   加工結果とユーザーへ渡すファイルは `outbox/` に置く。大きいファイルを
   `/srv/agent-work` の他の場所に置いたままにしない。
3. 書き込み完了後に `outbox/ファイル名` と、Windows から
   `\\samba.kojigenba-srv.com\hermes\outbox\ファイル名` で見えることを伝える。
   同名の既存成果物を勝手に上書きしない。書き込み中のファイルを完成品として案内しない。

## 小さい添付と扱いの制約

- 小さい画像などは従来どおり `MEDIA:/srv/agent-work/share/outbox/画像.png` で
  ユーザーへ返してよい。remote MEDIA は指定パスと realpath の両方を denylist で検査する。
  通常の NFS ファイルの realpath は共有パスのままで許可される。
  禁止領域への symlink、strict mode、サイズ上限や配送先の制限で失敗し得る。
  大きいファイルは SMB のパスで渡す。policy を回避するためのコピーはしない。
- 共有の中身を外部サービスへアップロードしない。明示的にユーザーへ返す小さい MEDIA 添付は
  上の手順に従う。共有全体を送信したり、共有ファイルを検索・URL取得へ渡したりしない。
- inbox/outbox は使い方の約束で、権限による分離ではない。双方が両方を読み書きできる。
- スナップショット・バックアップ・自動削除は無い。唯一のコピーや機密を置かない。
  NFS 障害時は hard mount によりコマンドが待つことがある。操作を増やさずユーザーへ伝える。
