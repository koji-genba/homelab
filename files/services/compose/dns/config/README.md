AdGuard Homeの書込み可能な設定は、SOPS runtime bundleからAnsibleが`/etc/homelab/adguard`へ生成する。
このdirectoryをGit checkoutの外に置くことで、AGH migrationやUI変更によってreconcile checkoutがdirtyに
なることを防ぐ。このdirectoryにはこの説明だけを置く。`AdGuardHome.yaml.j2` templateにはlegacy rewriteと、
review済みのGit allow/block ruleも含まれる。
