`allowlist.txt` / `blocklist.txt`はlocal exceptionを記録した、review済みGit sourceである。
[AdGuard template](../../../../infrastructure/ansible/apps/roles/secrets/templates/AdGuardHome.yaml.j2)の
`user_rules`へ組み込む。上流HaGeZiの6 list（Pro / TIF / DoH-VPN-Proxy / Dynamic DNS / Hoster /
URL Shortener）も同templateで定義する。
[secrets role](../../../../infrastructure/ansible/apps/roles/secrets/tasks/main.yml)が実行時設定を
`/etc/homelab/adguard/AdGuardHome.yaml`へ生成する。
review済み変更を管理端末のcheckoutへ取り込み、`make ansible-apply`で反映する。
reconcileのcheckout更新だけでは生成済み設定に反映されない。UI/APIでの変更は次のAnsible適用で再生成される。
設定変更時はcutover有効ならDNS・SMBを含む全Compose projectがforce-recreateされる。
credentialや生成済みAdGuard databaseはcommitしない。
