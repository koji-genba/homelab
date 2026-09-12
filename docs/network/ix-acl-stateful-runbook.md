# IX2215 ACL stateful化 実施手順書

- 状態: 投入前レビュー待ち
- 日付: 2026-09-13
- 対象: IX2215-HOME（IX Series IX2215 magellan-sec, Version 10.11.6）
- 目標ポリシー: [目標ネットワークゾーン](target-zones.md)
- 進捗: [次セッションへの作業指示のPhase 4](../migration/next-session.md)

**この文書はInternetが切れても参照できるようローカルで完結させる。** IX2215の変更中は管理端末の
Internet接続とAIセッションの双方を失う可能性を前提とし、console接続した操作者がこの文書だけで
投入・確認・rollbackを完遂できることをゲートとする。

## 0. 原則

- **consoleを開いた状態で投入する。** SSH経由では行わない。
- **すべての確認が終わるまで`write memory`しない。** 失敗したら`reload`で現在のstartup-configへ戻る。
- 旧設定（seq 10のstatic filterと`*-out`のACL定義）は最後まで消さない。1コマンドで戻せる状態を保つ。
- 投入は1段階ずつ。各段階の確認が終わるまで次へ進まない。

## 1. 設計の要点

### 1.1 なぜBVI20だけに置くのか

動的フィルタのキャッシュは**インタフェース単位**で、そのインタフェースを通過するパケットにしか
マッチしない（機能説明書 2-429）。したがって「発信元BVIの`in`で穴を開け、同じBVIの`out`で戻りを通す」
という形にしかできない。

目標ポリシーのうち**stateful性が必要なのは「Trustedゾーンへの戻りだけを通す」の1点だけ**である。

| フロー | 必要な性質 | 実現場所 |
| --- | --- | --- |
| Trusted → Server / IoT の新規 | 静的に許可 | 発信元BVI20の`in`（既存`main-out`） |
| Server → Trusted の新規 | **拒否** | 宛先BVI20の`out`（新設`trusted-in`） |
| Server → Trusted の応答 | **許可** | BVI20の動的キャッシュ |
| IoT → Trusted の新規 | **拒否** | 同上 |
| IoT → Trusted の応答 | **許可** | 同上 |
| Server → IoT / Guest | 拒否 | 既存`server-out`（BVI10 `in`） |
| IoT → Server / Guest | 拒否 | 既存`iot-out`（BVI30 `in`） |
| Guest → すべてのprivate | 拒否 | 既存`guest-out`（BVI40 `in`） |
| 全ゾーン → Internet | 許可 | 各リスト末尾の`permit any any` |

Server・IoT・Guestの各ゾーンは「誰も新規接続を張ってこない」ので、宛先側の`out`フィルタも
動的フィルタも要らない。発信元側の既存staticで足りる。**触るのはBVI20の1枚だけであり、
事故ったときの影響範囲もそこに限定される。**

### 1.2 `in`と`out`の意味

- `in` = そのインタフェースで**受信**したパケット（IXが受け取る向き）
- `out` = そのインタフェースから**送信**するパケット（IXが送り出す向き）

既存の`ip filter server-out 10 in`は、名前が`-out`なだけで実体は「Serverゾーンから出ていく
（＝IXが受信する）」方向のフィルタである。名前と方向が食い違って見えるが設定意図としては正しい。

### 1.3 暗黙のdeny

ある方向にフィルタを1本でも適用すると、その方向は「どのフィルタにもマッチしないパケットを廃棄」
する挙動になる（機能説明書 2-421、FAQ Q.1-6）。**BVI20の`out`側は現在フィルタが1本も無いので、
`trusted-in`には末尾`permit ip src any dest any`が必須である。** これを忘れるとVLAN 20の
インターネット戻り、DHCP応答、IX自身の送信がすべて廃棄され、Trustedゾーンが丸ごと死ぬ。

### 1.4 IX自身のアドレスの救済

Trusted端末からIXの管理IP（例`192.168.10.1`）へSSHすると、応答の送信元は`192.168.10.1`になる。
これはBVI20の`out`を通るため`deny 10.0/24 → 20.0/24`に当たってしまう。`trusted-in`の先頭に
各ゲートウェイアドレスの`/32 permit`を置いて救済する。

**運用ルール: IXへ接続するときは自分がいるゾーンのゲートウェイアドレスを使う。** Trustedからなら
`192.168.20.1`。応答の送信元が`192.168.20.1`になり、どのdenyにも当たらない。

### 1.5 同名ACLの落とし穴

コマンドリファレンス 13-3のノート: 「同一名称のアクセスリストとダイナミックアクセスリストが
存在した場合、ダイナミックアクセスリストが評価されます。」

`ip access-list dynamic main-out ...`のように既存static名で作ると、インタフェース設定を触らずに
`ip filter main-out 10 in`の意味が黙って動的へ切り替わる。**この手順では別名を使い、この挙動には
依存しない。** アクセスリスト名は15文字以内。

## 2. 変更内容

現在の`main-out`と`iot-out`から1行ずつ書き換え、ACLを2本新設し、BVI20にフィルタを2本足す。

| 変更 | 内容 |
| --- | --- |
| `main-out`の1行 | `deny 20→30`を`permit 20→30`へ（Trusted→IoTを許可） |
| `iot-out`の1行 | `deny 30→20`を`permit 30→20`へ（IoT→Trustedの応答を通す。新規はBVI20の`out`で落とす） |
| 新設`trusted-trig` | 動的フィルタのトリガ |
| 新設`trusted-dyn` | ダイナミックアクセスリスト |
| 新設`trusted-in` | BVI20の`out`側static |
| BVI20 | `ip filter trusted-dyn 5 in`と`ip filter trusted-in 5 out`を追加。既存seq 10は残す |
| 管理plane | `ssh-server`と`http-server`にsource ACLを設定 |

## 3. 投入手順

### 段階0: 事前取得（無停止）

```
show running-config
show ip filter
show ip access-list
show ip filter statistics
```

出力をローカルへ保存する。consoleでloginできることを確認しておく。

### 段階1: ACL定義の投入（インタフェース未適用なので無影響）

```
configure terminal
!
ip access-list trusted-trig permit ip src 192.168.20.0/24 dest 192.168.10.0/24
ip access-list trusted-trig permit ip src 192.168.20.0/24 dest 192.168.30.0/24
ip access-list trusted-trig permit ip src any dest any
!
ip access-list dynamic trusted-dyn access trusted-trig
!
ip access-list trusted-in permit ip src 192.168.10.1/32 dest 192.168.20.0/24
ip access-list trusted-in permit ip src 192.168.30.1/32 dest 192.168.20.0/24
ip access-list trusted-in permit ip src 192.168.40.1/32 dest 192.168.20.0/24
ip access-list trusted-in deny ip src 192.168.10.0/24 dest 192.168.20.0/24
ip access-list trusted-in deny ip src 192.168.30.0/24 dest 192.168.20.0/24
ip access-list trusted-in deny ip src 192.168.40.0/24 dest 192.168.20.0/24
ip access-list trusted-in permit ip src any dest any
```

確認:

```
show ip access-list trusted-trig
show ip access-list trusted-in
```

期待: `trusted-trig`が3エントリ、`trusted-in`が7エントリ。順序が上記と一致していること。

### 段階2: Trusted→IoTの許可とIoT→Trustedの戻り（低リスク）

```
no ip access-list main-out deny ip src 192.168.20.0/24 dest 192.168.30.0/24
ip access-list main-out permit ip src 192.168.20.0/24 dest 192.168.30.0/24
!
no ip access-list iot-out deny ip src 192.168.30.0/24 dest 192.168.20.0/24
ip access-list iot-out permit ip src 192.168.30.0/24 dest 192.168.20.0/24
```

**注意: この2行を入れた時点ではまだstatefulではない。** IoT→Trustedの新規接続も通る状態になる。
段階4でBVI20の`out`を入れるまでの間だけ、一時的に緩い。

確認: Trustedの端末からIoT機器へping/接続できること。既存の通信が切れていないこと。

```
show ip access-list main-out
show ip access-list iot-out
```

期待: 追加した`permit`行が末尾の`permit any any`より**前**にあること。順序が逆なら削除して入れ直す。

### 段階3: BVI20の入力へ動的フィルタを追加（許可集合は変わらない）

```
interface BVI20
  ip filter trusted-dyn 5 in
  exit
```

既存の`ip filter main-out 10 in`は**残す**。seq 5が先に評価され、`trusted-trig`の末尾が
`permit any any`なのでseq 10には落ちない。

確認:

```
show ip filter BVI20
show ip filter statistics BVI20
show ip filter dynamic BVI20
```

期待: BVI20に`trusted-dyn`（seq 5, in）と`main-out`（seq 10, in）の2本。
`Dynamic filter process counter`の`receives`と`passes`が増えていること。

**ここで数分待ち、主要な通信を1回ずつ発生させてキャッシュに載せる。**

- Trusted端末 → Apps VM（`192.168.10.101`）のHTTPSとSMB
- Trusted端末 → Proxmox（`192.168.10.11:8006`）
- Trusted端末 → ECW管理（`192.168.10.2`）
- 稼働中のSSHセッションで何かキー入力する

**段階3より前から張りっぱなしで、以後1パケットも流れていないセッションはキャッシュに載らない。**
そのまま段階4へ進むと、そのセッションの応答が落ちる。長時間アイドルのSSHは張り直しておく。

### 段階4: BVI20の出力へstaticを追加（**最も危険**）

ここでServer→TrustedとIoT→Trustedの新規接続がdenyになる。

```
interface BVI20
  ip filter trusted-in 5 out
  exit
```

**即座に確認すること:**

- consoleのプロンプトが生きていること
- Trusted端末からApps VMへのSSH/HTTPSが継続していること（切れたら段階3のキャッシュ漏れ）
- Trusted端末からインターネットへ到達できること
- Trusted端末でDHCP更新ができること（`ipconfig /renew`等）

切れた場合は5章のrollbackを即実行する。

```
show ip filter statistics BVI20
```

期待: `Implicit deny counter`が跳ね上がっていないこと。跳ねていれば`trusted-in`末尾の
`permit any any`が抜けている。

### 段階5: 旧staticの撤去

```
interface BVI20
  no ip filter main-out 10 in
  exit
```

`main-out`のACL定義自体は残す（rollback用）。全検証が終わってから別途削除する。

確認: 段階4と同じ項目に加え、Trusted→IoTが通ること。

### 段階6: IX自身の管理plane制限

```
ip access-list mgmt-src permit ip src 192.168.10.0/24 dest any
ip access-list mgmt-src permit ip src 192.168.20.0/24 dest any
ssh-server ip access-list mgmt-src
http-server ip access-list mgmt-src
```

現状は`ssh-server ip enable`と`http-server ip enable`があるだけでACL指定が無く、**IoTとGuestから
IXの管理planeへ到達できる**。SSHサーバはsrcのみを判定する（機能説明書 7-2）。http-server側が
destも見る可能性があるため`dest any`にして両方の解釈で安全にしている。

確認: Trustedから`ssh 192.168.20.1`できること。IoT/Guestの端末から`192.168.30.1`/`192.168.40.1`の
SSHとHTTPが拒否されること。

### 段階7: 受入試験と保存

4章の試験行列をすべて実施し、合格を確認してから:

```
exit
write memory
```

## 4. 受入試験の行列

| 発信元 | 宛先 | 期待 |
| --- | --- | --- |
| Trusted | Server（`.10.101`のHTTPS/SMB） | 成功 |
| Trusted | Server（`.10.11` PVE、`.10.2` ECW） | 成功 |
| Trusted | IoT | 成功（今回から許可） |
| Server | Trusted への新規接続 | **失敗（timeout）** |
| Server | Trusted が張ったセッションへの応答 | 成功 |
| IoT | Server / Trusted への新規接続 | 失敗 |
| IoT | Trusted が張ったセッションへの応答 | 成功 |
| Guest | Server / Trusted / IoT | 失敗 |
| 全ゾーン | インターネット | 成功 |
| 全ゾーン | 自ゾーンでのDHCP取得・更新 | 成功 |
| Server / Trusted | `ssh 192.168.10.1` / `ssh 192.168.20.1` | 成功 |
| IoT / Guest | `ssh 192.168.30.1` / `192.168.40.1`、HTTP | **失敗** |
| tailnet | `.10.101`のDNS/HTTPS/SMB | 成功 |
| — | sFlowが`.10.103`へ届き続けている | 成功 |

denyが効いていることは、カウンタでも確認する。

```
show ip access-list trusted-in
```

期待: Server→Trustedの新規接続を試した直後に`deny 10.0/24 → 20.0/24`行のヒットが増える。
**ヒットが増えないのに接続が失敗している場合、別の理由で落ちている。**

廃棄ログを見るなら:

```
logging subsystem flt warn
show logging
```

形式: `FLT.008: BLOCK icmp 10.0.0.1 > 10.0.0.254, no match, [IF名] out`
`info`や`debug`は通過パケットも記録してCPU負荷が高い。検証後は`warn`へ戻す。

## 5. Rollback

**最短復旧。** 暗黙denyを起こしているのはBVI20の`out`だけなので、まずこれを外す。

```
configure terminal
interface BVI20
  no ip filter trusted-in 5 out
  exit
```

**完全復旧。**

```
interface BVI20
  ip filter main-out 10 in
  no ip filter trusted-dyn 5 in
  exit
!
no ip access-list main-out permit ip src 192.168.20.0/24 dest 192.168.30.0/24
ip access-list main-out deny ip src 192.168.20.0/24 dest 192.168.30.0/24
no ip access-list iot-out permit ip src 192.168.30.0/24 dest 192.168.20.0/24
ip access-list iot-out deny ip src 192.168.30.0/24 dest 192.168.20.0/24
!
no ssh-server ip access-list
no http-server ip access-list
no ip access-list mgmt-src
!
no ip access-list dynamic trusted-dyn
no ip access-list trusted-trig
no ip access-list trusted-in
!
clear ip filter dynamic
clear ip ufs-cache
```

**最終手段。** `write memory`していなければ`reload`でstartup-configへ戻る。
ただし現在のstartup-configはPhase 4のVLAN撤去まで反映済みなので、reloadしてもVLAN 11/63は戻らない。

## 6. 投入前に実機で埋める空欄

公式マニュアルに記載が無く、**投入時に初回だけ実測して確定する項目**。ここを推測で埋めない。

1. **`show ip filter dynamic BVI20`の出力形式。** コマンドの存在はコマンドリファレンス13-4で確認済みだが、
   表示項目の一覧がマニュアルに無い。段階3の直後に1回取得し、この文書へ貼る。
2. **動的キャッシュがstaticより先に評価されること。** 設定事例集7.3（`out`に全廃棄staticを置きつつ
   `in`の動的で戻りを通す例）と機能説明書2-426から、事例としてはそう動く。**この手順書全体が
   この挙動に依存している。** 段階4の直後、Trusted→Serverの既存セッションが生き残るかが最初の関門。
3. **自装置宛パケットが動的キャッシュを生成するか。** 自装置「発」（DDNS更新）は公式事例で確認できたが、
   自装置「宛」は記載が無い。だから1.4の救済permitと運用ルールを併記している。
4. **トリガリスト内の`deny`にマッチしたときの挙動。** 廃棄か、次のseqへ落ちるか不明。
   この手順の`trusted-trig`は`permit`だけで構成しているため影響を受けない。

第三者の技術ブログに「NEC IXのDynamic ACLは意図せぬ通信まで許可する挙動だった」という報告がある
（検証バージョンの記載なし、公式に該当する制限事項の記述は無い）。**だからこそ4章のdenyヒット
カウント確認を必須にしている。**

## 7. 対象外

- **IPv6。** 現在BVIにIPv6アドレスは無く、IPv6 routeもneighborも0件のため、IPv4 ACLを迂回する経路は
  無い。RA/DHCPv6/forwardingの明示的な無効化は別タスクとする。
- **`ip dynamic-filter group`によるキャッシュ共有。** これを使えばゾーン横断でキャッシュを共有でき、
  より厳密な設計も可能だが、NECが「主にSIPダイナミックフィルタを使用する一部の環境での利用を想定」と
  明記しているため採用しない。

## 8. 出典

すべてver.10.11対応版（実機と同じ系統）。

- コマンドリファレンスマニュアル — <https://www.support.nec.co.jp/View.aspx?id=3170102594>
  - 13-3 IPv4パケットフィルタの設定（`ip filter`の構文、`in`/`out`の定義、同名ACLのノート）
  - 24-6 アクセスリスト / ダイナミックアクセスリストの定義
  - 24-7 `ip access-list dynamic cache` / `timer`の既定値
- 機能説明書 — <https://www.support.nec.co.jp/View.aspx?id=3170102598>
  - 2-421〜2-430 フィルタの評価順、暗黙deny、動的フィルタのキャッシュ単位
  - 7-2 SSHサーバのアクセスリスト（srcのみ判定）
  - 8-56〜8-57 `show ip filter statistics`の表示項目
- 設定事例集 — <https://www.support.nec.co.jp/View.aspx?id=3170102600>
  - 7.3 DMZ構築（`in`に動的、`out`にstatic denyの組み合わせ）
  - 18-52、18-133 自装置宛・自装置発パケットにフィルタが効く実例
- FAQ MAC/IPフィルタ — <https://jpn.nec.com/univerge/ix/faq/filter.html>
- FAQ IPv4, NAT, DHCP — <https://jpn.nec.com/univerge/ix/faq/ip.html>
