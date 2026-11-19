# ADR-0017: operator認証情報とTerraform入力の既定値をrepoで管理する

- 状態: 採用。fixtureで検証、実機の移行・7 rootのNo changes確認は未検証
- 日付: 2026-11-19
- 置換対象: [ADR-0005](0005-secrets-and-terraform-state.md)のprovider認証情報の一時注入方針

## 背景

makeのたびの手入力と端末ごとのtfvarsをなくし、端末をそろえる。
Tailscaleのgate指定漏れで管理resourceの削除planになる危険もなくす。
state同期とlockは[ADR-0016](0016-terraform-state-sync-lock.md)を継続する。

## 決定

age identityは`~/.config/sops/age/keys.txt`を既定とし、Makeからhost scriptへもexportする。
公開recipientの既定値は`files/infrastructure/secrets/age-recipient.txt`だけに置く。
既存4 bundleのSOPSメタデータが同じrecipientであることを確認した。明示指定は優先する。

providerごとに`operator/proxmox.sops.yaml`と`operator/tailscale.sops.yaml`を保存する。
SOPS 3.10.2のexec-envに合わせ、トップレベルの文字列キーと文字列値だけにする。
ホストで非表示入力し、stdinでtoolboxへ送り暗号化する。平文はディスクに保存しない。
キー検査後にtoolbox内で`sops exec-env`を使い、対応するTerraformプロセスだけへ渡す。
明示環境変数は同名bundle値より優先。Tailscaleは明示API keyをOAuthより優先し、
明示OAuthの一部があればOAuth方式を選び、不足分だけbundleから補う。
bundleはOAuthの2キーまたはAPI keyのどちらか一方にする。bundleが無ければ従来のallowlistを使う。
存在するbundleが壊れている場合や復号できない場合は停止し、環境変数へ黙ってfallbackしない。
値をMake引数、Dockerの`-e NAME=value`、shell command文字列へ展開しない。

VM用の公開鍵は作業端末の`~/.ssh/id_ed25519.pub`の1行をコメント付きでrepoへ保存し、末尾改行は1つにする。
6 rootのnull/未指定時の既定値として、apps-vm・agent-vm・runner-vm・tailscale-gatewayは行全体を使い、
elastiflow・stashpad-devだけ先頭2フィールドを使う。明示のTF_VARは加工せず優先する。
既存VMの作成時の値に合わせる判断であり、本人が実機planで上記の形式なら各rootがNo changesになると確認した。
公開鍵のコメントには作業端末のユーザー名とホスト名が含まれて公開repoに載るが、既存VMとの一致のため本人が了承した。
Tailscale providerのtailnet引数と変数を削除し、`TAILSCALE_TAILNET`、次いでproviderの`"-"`を使う。
本番gateは既存のMakeの`-var`と整合する`?=`へ置き、明示指定を優先する。
hostname/tags/routesは既存のvariables.tfの既定値を継続する。根拠・推測は[Tailscale README](../../files/infrastructure/terraform/tailscale/README.md)に記す。

暗号化ACLを正本へ格上げする。ACL_POLICY_FILE未指定のplan/importはtoolbox内の固定パス
`tmp/tailscale-acl/policy.json`へ、親0700・file0600で一時復号する。
saved planのapplyでも設定式が再評価されるため、apply前にも同じパスへ正本を復号する。
applyは`terraform show -json`の`variables.acl_policy_file.value`だけをメモリ内で参照して判定し、
JSONの内容は表示しない。明示パスのplanは元のfileを検査して使う。applyに`-var`は追加しない。
旧ランダムパスのplanは作り直す。固定directoryの排他的な作成で同時実行を拒否し、
自分が作成したfile/directoryだけを成功・失敗・TERM時に削除する。
SIGKILL等の残存fileは全実行の停止を確認して本人が削除する。実機apply手順は未検証。手元のlive.jsonとのbyte不一致は停止し、本人が判断する。
明示ACL_POLICY_FILEは従来のpath検査を通す。保存planにはACL全文が残るので0600・ignoreを継続する。
4 rootのtfvarsは不要。exampleは任意の非秘密の上書き用として残す。

## 危険の評価と復旧

age鍵が漏れたときに読まれる範囲は、この2つのprovider認証情報の分だけ広がる。
ただし同じ鍵ですでにruntimeシークレットとstateが読め、作業端末はpve1へrootでSSHできる。
この作業端末の信頼境界を継続し、provider別bundleをVMへ配布しない。
Hermesの復旧試験でage鍵をAgent VMへ一時投入する場合、この2つの認証情報も読める状態になる。
試験後は鍵を削除し、常設しない。KeePassXCはage鍵の復旧コピーと認証情報の控えのため残す。
ssh-agentの起動・鍵登録は従来どおり利用者が行う。

移行はbundle作成 → tfvars退避 → 7 rootのplanでNo changes確認 → 退避file削除。
公開鍵のコメントだけでもcloud-init/user_account.keysに差分が出るため、既存VMに合わせて上記のroot別の扱いを維持する。
自動applyしない。実機手順は未検証。
