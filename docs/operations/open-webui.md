# Open WebUI運用

- 状態: 2026-10-10にpve1とApps VMへ反映し、browserからのログイン・chat応答まで確認済み
- 関連: [アプリ更新・promotion・rollback](application-lifecycle.md)、
  [NFS export契約](nfs-export.md)、[DGX Sparkストレージ運用](dgx-storage.md)、
  [ADR-0001](../adr/0001-single-apps-vm-compose.md)
- 対象: `open-webui` Compose project（`https://openwebui.kojigenba-srv.com`）

DGX Spark 4TB機のvLLM（OpenAI互換API）に接続するchat UIとして、Open WebUIをApps VMに置く。

## 構成

```text
browser
  -> Caddy (openwebui.kojigenba-srv.com, TLS)
  -> open-webui:8080 (homelab_frontend network)
  -> vLLM http://192.168.10.51:8000/v1 (DGX Spark 4TB機、API keyなし)
```

- 到達元の制限は既存どおりnftablesとIX2215 ACLで行う。Host portは公開しない
- DGXもServer VLAN 10なので、IX2215のACL変更は不要である
- imageはv0.11.4のdigestでpinする（`files/services/compose/open-webui/compose.yaml`）
- dataは`/mnt/tank-gen2/data/k8s-volumes/open-webui`（pve1）→ `/srv/homelab/nfs/open-webui`
  （Apps VM）→ container `/app/backend/data`の順にmountされる
- Compose project名は`homelab-open-webui`で、lifecycle helperが導出する

## 設計上の判断

- **dataは既存の`k8s-volumes`親exportの下に置く。** この親exportはすでにApps VM `/32`へ公開済み
  なので`/etc/exports`は変わらず、directoryとmarkerを足すだけで済む。`k8s-volumes`には自動
  snapshotがない（[NFS export契約](nfs-export.md)）ため、chat履歴はsnapshotされない
- **runtime secretをSOPS bundleへ足さない。** session署名keyはimageが
  `/app/backend/data/.webui_secret_key`へ生成する（`WEBUI_SECRET_KEY_FILE`）。dataと一緒に
  復元される。このfileを消すと全userがsign outされる
- **SQLiteはNFS上にあるのでWALを無効にする。** `DATABASE_ENABLE_SQLITE_WAL=false`と
  `DATABASE_SQLITE_PRAGMA_SYNCHRONOUS=FULL`を指定している。dataがNFS上にある間はWALを
  再度有効にしない
- **`WEBUI_URL`、`ENABLE_OLLAMA_API`、`OPENAI_API_BASE_URL`は初回起動時のseed値である。**
  初回起動でDBへ保存され、以後`compose.yaml`を変えても反映されない。接続の変更（1TB機
  `192.168.10.52`の追加、別port/別model serverなど）はadmin設定UIで行う。
  `CORS_ALLOW_ORIGIN`、`DATABASE_*`、`WEBUI_SECRET_KEY_FILE`は毎回の起動で読まれる
- **vLLM自体はGatus endpointにしない。** DGXは他の作業で停止・再起動するため、通知を飛ばさない
  ためである。DGX停止中もOpen WebUIはhealthyのままで、model一覧が空になるだけである
- **`compose_wait_timeout_seconds`を120から300へ上げた。** imageに同梱されたembedding model
  （`sentence-transformers/all-MiniLM-L6-v2`一式、約890 MB）は`/app/backend/data/cache`にあり、
  bind mountで隠れる。このため空のdata directoryでの初回起動だけ、Hugging Faceから取得し終える
  までhealthyにならない。Apps VMからの事前実測（単一stream）は約15 MB/sで、取得だけで約1分かかる
  見込みだった。healthcheckの`start_period`（240s）は`compose_wait_timeout_seconds`より短く保つ。
  2回目以降の起動は取得を行わない

## 手順A: pve1（`192.168.10.11`、rootで実行）

repoはNFS serverを変更しないので、他の作業より先に手動で行う。

```sh
install -d -o root -g root -m 0750 /mnt/tank-gen2/data/k8s-volumes/open-webui
printf '%s\n' open-webui-data > /mnt/tank-gen2/data/k8s-volumes/open-webui/.homelab-export
exportfs -v | grep k8s-volumes
```

containerはrootで動き、exportは`no_root_squash`なので`root:root 0750`で足りる。Ansibleが新しい
mountを描画した後にmarkerが無いと、mount guardが**全project**で失敗する。このため必ず最初に行う。

## 手順B: 反映順序

順序を入れ替えない。

1. PRを`main`へmergeする。
2. Apps VMのcheckoutを進める。`ssh deploy@192.168.10.101 sudo systemctl start homelab-app-reconcile.service`
   （または15分のtimerを待つ）。Ansibleは`/opt/homelab`を更新しない（git taskが`update: false`）。
   checkoutに`open-webui/compose.yaml`が無いと、digest gateも`homelab-compose-up all`も
   `missing Compose project`で失敗する。
   このreconcileは`.env.example`が変わるため既存projectを一度ずつ再作成する（DNS/SMBが短時間
   途切れる）。また、まだ古いhelperはopen-webuiを起動しないため、手順3までGatusは
   Open WebUIをdownと報告し、3回失敗後にDiscord通知が出る。
3. `AGE_IDENTITY_FILE=/secure/path/age-identity.txt make ansible-apply`を実行する。新しいNFS pathの
   mount、mount guard・helper・`compose.env`・AdGuard rewriteの再描画、open-webuiを含む全projectの
   force-recreateが行われる（2回目の短い中断）。open-webuiは初回だけimage（約6.5 GB）のpullと
   embedding model（約890 MB）の取得を行うため、このtaskは数分かかる。

2と3は静かな時間帯に続けて行うことを推奨する。

## 手順C: 初回セットアップ

`https://openwebui.kojigenba-srv.com`を開く。**最初に作成したaccountが管理者になる**ので、反映
直後にすぐ作成する。以降のsign-upは管理者が承認するまで`pending`のままである。model選択に
`glm-5.3-flash`が出ることを確認する。

## 検証

| 項目 | 確認方法 | 結果 |
| --- | --- | --- |
| pve1 directory/marker | `ls -ld /mnt/tank-gen2/data/k8s-volumes/open-webui; cat /mnt/tank-gen2/data/k8s-volumes/open-webui/.homelab-export` | 2026-10-10 作成・確認済み（`root:root 0750`） |
| Apps VM mount + marker | `ssh deploy@192.168.10.101 'findmnt /srv/homelab/nfs/open-webui; cat /srv/homelab/nfs/open-webui/.homelab-export'` | 2026-10-10 確認済み（nfs4、`nconnect=8`、mount guard通過） |
| `docker compose ps`がhealthy | `ssh deploy@192.168.10.101 sudo docker compose --project-name homelab-open-webui --env-file /etc/homelab/compose.env -f /opt/homelab/files/services/compose/open-webui/compose.yaml ps` | 2026-10-10 確認済み。初回起動は約50秒でhealthy |
| FQDNへのアクセスとTLS | `curl -sI https://openwebui.kojigenba-srv.com` | 2026-10-10 確認済み（`/health`が200、Let's Encrypt証明書、WebSocketは101） |
| 初回admin作成 | browserで作成 | 2026-10-10 確認済み |
| model一覧に`glm-5.3-flash` | `curl -s http://192.168.10.51:8000/v1/models`とmodel selector | 2026-10-10 確認済み（container内のcurlとbrowserのmodel selector） |
| chat応答 | `glm-5.3-flash`へ短い入力を送る | 2026-10-10 確認済み |
| Gatus `Open WebUI`がgreen | `https://status.kojigenba-srv.com` | 2026-10-10 確認済み（全endpointがsuccess） |
| container再作成後もloginが維持される | `ssh deploy@192.168.10.101 sudo env HOMELAB_FORCE_RECREATE=true /usr/local/sbin/homelab-compose-up open-webui`後に再読込 | 2026-10-10 確認済み（17秒でhealthy、`.webui_secret_key`と`webui.db`は不変、browserのloginも維持） |

### 実機反映の記録（2026-10-10）

PR #63（merge commit `78e6194`）を手順A、Bの順で反映した。reconcileは既存7 projectを再作成して成功し、
`make ansible-apply`は`ok=102 changed=15 failed=0`で完了した。imageは事前に`docker pull`して
おいた。

| 項目 | 結果 |
| --- | --- |
| 初回起動 | container開始からserver起動まで28秒、healthyまで約50秒 |
| 初回起動後のdata directory | 888 MB（ほぼembedding modelのcache） |
| SQLite | NFS上で`journal_mode=delete` |
| AdGuard rewrite | `openwebui.kojigenba-srv.com`が`100.86.147.127`へ解決 |
| dead-man ping | `homelab-healthchecks-ping.service`が成功 |
| rootfs | 26%（image追加後） |

### ローカル検証（2026-10-10）

実機反映の前に、同じ`compose.yaml`とdigestを作業端末のDockerで起動し、実際のvLLM
（`192.168.10.51:8000`）へ接続して確認した。data directoryはlocal diskであり、NFS上の挙動は
含まない。

| 項目 | 結果 |
| --- | --- |
| `up --wait`（空のdata directory） | 34秒でhealthy。うち約25秒がembedding modelの取得 |
| `up --wait --force-recreate`（2回目） | 13秒でhealthy。再取得なし |
| 上流DNSが応答しない状態での再作成 | 31秒でhealthy |
| SQLite | `journal_mode=delete`、`-wal`/`-shm`なし |
| 最初のsign-up | roleが`admin` |
| model一覧 | `glm-5.3-flash`を取得 |
| chat completion | Open WebUI経由でvLLMから応答 |
| WebSocket handshake | `Origin: https://openwebui.kojigenba-srv.com`は101、他のOriginは403 |
| 再作成後のsession | 再作成前に発行したtokenが有効（`.webui_secret_key`が同一） |
| idle時のmemory | 約660 MiB |

## 更新とrollback

更新は`open-webui/compose.yaml`のdigestを上げるPRで行い、reconcileが反映する。Open WebUIは起動時に
DBをmigrationし、自動downgradeはない。version更新の前に、利用のない時間帯にpve1で`webui.db`を
copyしておく。

## 再deploy

通常はPRを`main`へmergeするだけで、reconcile（15分間隔）が変更のあるprojectだけを再作成する。
急ぐ場合はApps VMで`sudo systemctl start homelab-app-reconcile.service`を実行する。

| 変えたもの | 手順 | 影響 |
| --- | --- | --- |
| `open-webui/compose.yaml`（digest、環境変数） | PRをmerge。reconcileがopen-webuiだけを再作成する | 1分弱停止。loginは維持される |
| Caddyfile、Gatusの`config.yaml` | 同上（edge / monitoringだけ） | 該当projectのみ |
| Ansible管理のもの（`group_vars`、helper、AdGuard rewrite、NFS mount） | merge後に`make ansible-apply` | `compose.env`かAdGuard設定が変わると全projectを再作成する（DNS/SMBが短時間途切れる）。helperだけなら再作成なし |
| 変更なしで作り直す | `ssh deploy@192.168.10.101 sudo env HOMELAB_FORCE_RECREATE=true /usr/local/sbin/homelab-compose-up open-webui` | open-webuiのみ。2026-10-10の実測は17秒 |

接続先（`OPENAI_API_BASE_URL`など）の変更は`compose.yaml`では反映されない。admin設定UIで行う。
Apps VMを作り直す場合、data・session鍵・modelのcacheはNFS上にあるため、Open WebUI固有の作業はない
（[Apps VM復旧](apps-vm-recovery.md)）。

### Gatusの通知

新しいprojectの初回追加では、Gatusが監視先を読み込んでから`ansible-apply`が起動するまでの間、
「failed 3 time(s) in a row」の通知だけが届き、復旧通知は届かないことがある。このGatusは`storage:`を
持たずalert状態をmemoryにしか保持しないため、`ansible-apply`によるGatusの再作成で「alertが出ていた」
記録が消え、復旧通知を送らないからである。反映後にGatusのstatusがsuccessならば問題ない。

## rollback

rollbackは`PROJECT=open-webui`を指定した`make rollback-app`で行う（手順は
[アプリ更新・promotion・rollback](application-lifecycle.md#rollbackと再開)）。migration後の
DBは古いversionで読めないことがあり、その場合はcopyしておいた`webui.db`を戻す。

## 切り戻し（アプリの撤去）

追加時とは逆に、helperのproject一覧を先に戻す。checkoutだけが先に戻ると、古いhelperとdead-man pingが
`open-webui/compose.yaml`を見つけられずに失敗する。

1. Apps VMでprojectを止める。

   ```sh
   ssh deploy@192.168.10.101 sudo docker compose --project-name homelab-open-webui \
     --env-file /etc/homelab/compose.env \
     -f /opt/homelab/files/services/compose/open-webui/compose.yaml down
   ```

2. revertのPRを`main`へmergeし、reconcileを待たずに`make ansible-apply`を実行する。
3. reconcileでApps VMのcheckoutを進める。
4. Ansibleは宣言から外したNFS mountをunmountしない。Apps VMの`/etc/fstab`の該当行を消し、
   `umount /srv/homelab/nfs/open-webui`する。pve1のdirectoryはそのまま残す。
