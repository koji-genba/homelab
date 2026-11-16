# 作業端末の準備とTerraform state同期

[ADR-0016](../adr/0016-terraform-state-sync-lock.md)に従う単一利用者向け手順。
一時bare repoでのfixture以外、新端末・GitHub ruleset・実planでの通し手順は**未検証**。

## 最初の移行

既存管理端末で、**この変更を使う前に`make state-backup`を実行してbackupを最新にする**。
例えばtailscale-gatewayのlocalがbackupより新しい状態のまま、新端末で最初のplanをしない。
既存端末の全rootをbackupしてから変更を取り込む。実行には本人の承認が必要。

正本を自動同期する前に、本人がstate専用rulesetを別途反映・確認する。
次はAPIを呼ばず、予定する設定を表示するだけである。

```sh
python3 scripts/github-agent-repo.py protect-state koji-genba/homelab --dry-run
```

本人による反映は同commandの`--dry-run`を外す（GitHubへの書込み、実機未検証）。確認は
`python3 scripts/github-agent-repo.py check-state koji-genba/homelab`（読取りのみ、実機未検証）。
対象は個人repoで、adminのみbypass。main用の`--allow-deploy-key-bypass`はstateには付けない。
App・staging deploy key・Actionsはstate-backup/state-lockのbypassへ入れない。

## ツールと持っていく情報

Linux端末（WindowsならLinux環境を用意。WSL2での通し操作は未検証）を基本とする。
Git、GNU make、Docker Engine + Compose v2、OpenSSH（ssh-agent含む）、Bash、GNU coreutils/findutils、
Python 3 + PyYAML + Jinja2、ghを用意する。toolboxにTerraform・Ansible・SOPS・age・shellcheckが入っている。
公開toolboxは`linux/amd64`。ARM端末でのemulationは未検証。任意でTailscale（管理経路用）、
KeePassXC（復旧情報用）を導入する。Dockerの実行権限も確認する。

持ち出すものは次のとおり。秘密をterminal出力、chat、docs、Gitへ貼らない。

- KeePassXCのdatabaseと解除に必要なもの。age identity、public recipient、provider credentialの復旧entryを確認する。
- age identity。repoの外の安全な場所へ復旧しmode 0600にする。VMへは置かない。
- SSH鍵を安全な既存経路で移すか、新端末で新しい鍵を作る。新鍵ならGitHub本人accountへ公開鍵を登録し、
  VMの接続先は各Ansible inventoryと既存の認証運用に従って登録する。ホスト鍵の照合情報も引き継ぐ。
  deploy key/App tokenではstateのpush権限を代用できない。
- 各rootの`terraform.tfvars`。Git管理外のまま。旧端末から承認済みの暗号化転送経路、またはKeePassXC添付を介して
  rootごとに渡し、0600で配置する。移送用平文をrepoや共有directoryへ残さない。
  `terraform.tfvars.example`だけでは既存環境の全入力を復元できるとは限らない。
- provider credentialはKeePassXCから必要な環境変数へ一時注入する。Makefileのroot別allowlistを使い、tfvarsへ追加しない。

## 新端末で最初に行うこと

本人accountでrepoをcloneし、originのpush URLをSSHにする。SSH agentへ本人の鍵を登録し、
各Terraform rootのtfvarsを配置する。stateを手動copyする必要はない。公開ホスト名に個人情報が含まれる場合、
`STATE_LOCK_HOST`へ識別できる公開用別名を設定する。

```sh
export AGE_IDENTITY_FILE=/secure/path/age-identity.txt
export AGE_RECIPIENT='age1...'
# 必要なprovider環境変数はKeePassXCから安全に設定する
make terraform-plan TERRAFORM_ROOT=files/infrastructure/terraform/apps-vm
# Tailscaleは既存のgate・ACL入力も指定する
# make tailscale-plan ...
```

最初のplanはorigin/state-backupをfetchし、toolbox内で復号して各rootへstateを同期する。
**planにも`AGE_IDENTITY_FILE`が必要**。recipientは書込み後のbackup/preflightにも必要。
新端末での実planは未検証。planはprovider APIを読み、local stateとsaved planを配置する操作なので、
単なる静的検証とは区別する。applyは0600のsaved planを必要とし、その前にlock取得と再同期を行う。
plan後に正本が進んでいた場合はsaved planを作り直す。

localがbackupより新しければ止まる。元の更新端末で`make state-backup`を行ってから再試行する。
lineage不一致・同serial内容違いは自動解決せず、どちらが正しいか本人が判断する。
同期前のcopyは`terraform.tfstate.pre-sync.<UTC時刻>`として0600で残る。Git ignoreとmode検査の対象であり、
通常のstateと同じ秘密情報として管理する。

fetch不能時は止まる。接続不能中に既存localでplanを行う場合だけ、古い可能性を承知して
`STATE_SYNC=skip make terraform-plan ...`を明示する（警告あり、未検証）。
これはlockやbackupを省略せず、offline applyはできない。他端末のlockがあるplanは警告して続行する。

## 読取りだけの確認

次のversion確認とvalidateは実state・鍵を表示せず、GitHub/VMも変更しない。
validateはtoolbox起動とlocal provider初期化を行う。hostへのage/SOPS導入は不要。

```sh
git --version
make --version
docker --version
docker compose version
python3 -c 'import yaml, jinja2; print("Python dependencies: OK")'
gh --version
git status --short
make terraform-validate
make state-lock-status
```

`state-lock-status`はremoteを読むだけ（Gitのobject/FETCH_HEADはlocalに取得する）で、公開lock情報だけを表示する。
実GitHubでの確認は未検証。state、tfvars、鍵の中身を`cat`したり、stateブランチの暗号文を出力する必要はない。

## lockが残った場合

通常は変更があるときだけbackupし、成功・失敗・INT/TERMいずれも最後にunlockする。
backup失敗・SIGKILL・電源断ではlockを残す。期限だけで解除しない。

1. `make state-lock-status`でSHA・UTC・host・操作名を確認する。全端末のwriterが止まっていることを確認する。
2. backup失敗なら、**失敗した元端末で**認証・networkを復旧する。lockを保持したまま`make _state-backup`を実行する。
   これは内部targetの復旧用例外で、通常は`make state-backup`を使う。後者は新規lockを取り直すので、残ったlockで停止する。
   別端末の古いstateを先に同期・backupしない。実復旧は未検証。
3. 正本へのbackup成功とwriter停止を確認し、表示されたSHAの先頭12文字以上を使い
   `make state-unlock CONFIRM=<SHA先頭>`を実行する。確認指定なし・不一致は拒否し、
   確認後にlockが替わっていればleaseで削除を拒否する。実解除は未検証。
4. 次の作業では通常のplanを作り直す。途中まで変更された実resourceもplanで確認する。

`state-backup` branchは削除しない。内部`_state-*` targetは上の復旧例外以外、直接呼ばない。
Terraformを直接実行すると共有lock・sync・失敗時backupを通らないので、Makeの公開targetを使う。
