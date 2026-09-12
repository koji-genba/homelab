# IX2215 ACL stateful化 実施手順書

- 状態: 投入前レビュー待ち（2026-09-13にCodexレビューを反映して改訂）
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
- 既存のACL（`server-out`、`main-out`、`iot-out`、`guest-out`）は**消さない**。新しいフィルタを
  より若いシーケンス番号で重ねるだけにする。これによりrollbackは「足したものを外す」だけで済む。
- 投入は1段階ずつ。各段階の確認が終わるまで次へ進まない。

## 1. 設計の要点

### 1.1 何を足すのか

追加するのは**BVI20（Trusted）へのフィルタ2本だけ**である。

| フロー | 実現方法 |
| --- | --- |
| Trusted → Server の新規 | BVI20 `in` seq 5の動的フィルタ（`trusted-dyn`）でトリガし、キャッシュを作る |
| Trusted → IoT の新規 | 同上 |
| Trusted → Guest | **トリガにマッチしない**ので seq 10の既存`main-out`へ落ち、`deny 20→40`で拒否 |
| Trusted → Internet | 同じくseq 10へ落ち、`permit any any`で通過 |
| Server → Trusted の新規 | BVI20 `out`の`trusted-in`が`deny 10.0/24 → 20.0/24`で拒否 |
| Server → Trusted の応答 | BVI20の動的キャッシュが救済 |
| IoT → Trusted の新規 | `trusted-in`が`deny 30.0/24 → 20.0/24`で拒否 |
| IoT → Trusted の応答 | 動的キャッシュが救済 |
| Server → IoT / Guest | 既存`server-out`（BVI10 `in`）のdenyのまま |
| IoT → Server / Guest | 既存`iot-out`（BVI30 `in`）のdenyのまま |
| Guest → すべてのprivate | 既存`guest-out`（BVI40 `in`）のdenyのまま |
| 各ゾーン → Internet | 各リスト末尾の`permit any any` |

### 1.2 トリガに`permit any any`を置かない理由（重要）

**初版ではトリガリストの末尾に`permit ip src any dest any`を置いていた。これは誤りだった。**
seq 5ですべてがマッチしてしまい、seq 10の`main-out`にある`deny 20→40`へ到達せず、
**Trusted→Guestが素通りする**穴になっていた（2026-09-13、Codexレビューで指摘）。

現在の設計ではトリガを`20→10`と`20→30`の2行だけにする。マッチしないパケットは
「次のフィルタを評価する」（FAQ Q.1-5）ため seq 10の`main-out`へ落ち、そこで
Guest向けdenyとInternet向けpermitが従来どおり効く。

この「マッチしなければ次のseqへ落ちる」挙動が成立する条件は、**動的フィルタが最後のフィルタで
ないこと**である（機能説明書 2-424: 最後のフィルタがダイナミックフィルタで全てにマッチしない場合は
廃棄）。したがって**`ip filter main-out 10 in`は絶対に外さない**。外すとseq 5が最後になり、
Trusted→Internetが全滅する。

### 1.3 なぜBVI20だけなのか

動的フィルタのキャッシュは**インタフェース単位**で、そのインタフェースを通過するパケットにしか
マッチしない（機能説明書 2-429）。よって「発信元BVIの`in`でキャッシュを作り、同じBVIの`out`で
戻りを通す」形にしかできない。

目標ポリシーのうちstateful性が要るのは**「Trustedゾーンへの戻りだけを通す」の1点**である。
Server・IoT・Guestへは誰も新規接続を張らないので、宛先側`out`フィルタも動的フィルタも要らず、
発信元側の既存staticで足りる。触るインタフェースが1枚なら、事故の影響範囲もそこに限定される。

### 1.4 `in`と`out`の意味

- `in` = そのインタフェースで**受信**したパケット（IXが受け取る向き）
- `out` = そのインタフェースから**送信**するパケット（IXが送り出す向き）

既存の`ip filter server-out 10 in`は、名前が`-out`なだけで実体は「Serverゾーンから出ていく
（＝IXが受信する）」方向のフィルタである。

### 1.5 暗黙のdeny

ある方向にフィルタを1本でも適用すると、その方向は「どのフィルタにもマッチしないパケットを廃棄」
する挙動になる（機能説明書 2-421、FAQ Q.1-6）。**BVI20の`out`側は現在フィルタが1本も無いので、
`trusted-in`には末尾`permit ip src any dest any`が必須である。** これを忘れるとVLAN 20の
インターネット戻り、DHCP応答、IX自身の送信がすべて廃棄され、Trustedゾーンが丸ごと死ぬ。

### 1.6 IX自身のアドレスの救済

Trusted端末からIXの`192.168.10.1`へSSHすると、応答の送信元は`192.168.10.1`になる。これはBVI20の
`out`を通るため`deny 10.0/24 → 20.0/24`に当たる。`trusted-in`の先頭に各ゲートウェイアドレスの
`/32 permit`を置いて救済する。

**運用ルール: IXへ接続するときは自分がいるゾーンのゲートウェイアドレスを使う。** Trustedからなら
`192.168.20.1`。応答の送信元が`192.168.20.1`になり、どのdenyにも当たらない。

### 1.7 同名ACLの落とし穴

コマンドリファレンス 13-3のノート: 「同一名称のアクセスリストとダイナミックアクセスリストが
存在した場合、ダイナミックアクセスリストが評価されます。」既存static名で動的リストを作ると、
インタフェース設定を触らずに挙動が黙って変わる。この手順では別名を使う。名前は15文字以内。

## 2. 変更内容

| 変更 | 内容 | 段階 |
| --- | --- | --- |
| 新設`trusted-trig` | 動的フィルタのトリガ（2行、`permit any any`を**置かない**） | 1 |
| 新設`trusted-dyn` | ダイナミックアクセスリスト | 1 |
| 新設`trusted-in` | BVI20の`out`側static（7行、末尾`permit any any`） | 1 |
| BVI20 | `ip filter trusted-dyn 5 in`を追加（既存seq 10は**残す**） | 2 |
| BVI20 | `ip filter trusted-in 5 out`を追加 | 3 |
| `iot-out`の1行 | `deny 30→20`を`permit 30→20`へ（応答用。新規はBVI20の`out`で落ちる） | 4 |
| 管理plane | `ssh-server`と`http-server`にsource ACL | 5 |

`main-out`、`server-out`、`guest-out`は**一切変更しない**。

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

期待: `trusted-trig`が**2エントリ**（`permit any any`が無いこと）、`trusted-in`が7エントリで、
3つの`/32 permit`が`/24 deny`より**前**にあること。順序が違えば削除して入れ直す。

### 段階2: BVI20の入力へ動的フィルタを追加

```
interface BVI20
  ip filter trusted-dyn 5 in
  exit
```

**既存の`ip filter main-out 10 in`は残す**（1.2の理由。外すとInternetが落ちる）。

この時点で許可集合は変わらない。Trusted→IoTは、トリガがpermitしてseq 5で通るようになるが、
戻りは`iot-out`がまだdenyなので実質的には通らない。

確認:

```
show ip filter BVI20
show ip filter statistics BVI20
show ip filter dynamic BVI20
```

期待: BVI20に`trusted-dyn`（seq 5, in）と`main-out`（seq 10, in）の2本。
`Dynamic filter process counter`の`receives`/`passes`が増えること。
**Trusted端末からInternetへ到達できること**（seq 10へ落ちる経路が生きている証明）。
**Trusted端末からGuestへ到達できないこと**（seq 10の`deny 20→40`が効いている証明）。

`show ip filter dynamic BVI20`の出力をこの文書へ貼る（6章の空欄1）。

**ここで数分待ち、主要な通信を1回ずつ発生させてキャッシュに載せる。**

- Trusted端末 → Apps VM（`192.168.10.101`）のHTTPSとSMB
- Trusted端末 → Proxmox（`192.168.10.11:8006`）
- Trusted端末 → ECW管理（`192.168.10.2`）、Tailscale gateway（`.10.102`）、ElastiFlow（`.10.103:5601`）
- 稼働中のSSHセッションで何かキー入力する

**段階2より前から張りっぱなしで、以後1パケットも流れていないセッションはキャッシュに載らない。**
そのまま段階3へ進むと応答が落ちる。長時間アイドルのSSHは張り直しておく。

### 段階3: BVI20の出力へstaticを追加（**最も危険**）

ここでServer→Trustedの新規接続がdenyになる。

```
interface BVI20
  ip filter trusted-in 5 out
  exit
```

**即座に確認すること:**

- consoleのプロンプトが生きている
- Trusted端末からApps VMへのSSH/HTTPSが**継続**している（切れたら段階2のキャッシュ漏れ）
- Trusted端末からInternetへ到達できる
- Trusted端末でDHCP更新ができる

切れた場合は5章のrollbackを即実行する。

```
show ip filter statistics BVI20
```

期待: `Implicit deny counter`が跳ね上がっていないこと。跳ねていれば`trusted-in`末尾の
`permit any any`が抜けている。

**これが6章の空欄2（動的キャッシュがstaticより先に評価されるか）の検証ポイントである。**
既存のTrusted→Serverセッションが生き残れば、前提は成立している。

### 段階4: IoT→Trustedの戻りを通す

段階3を先に済ませてあるので、ここで開けても**新規のIoT→TrustedはBVI20の`out`で落ちる**。

```
no ip access-list iot-out deny ip src 192.168.30.0/24 dest 192.168.20.0/24
ip access-list iot-out permit ip src 192.168.30.0/24 dest 192.168.20.0/24
```

確認:

```
show ip access-list iot-out
```

期待: 追加した`permit 30→20`が末尾の`permit any any`より**前**にあること。
Trusted端末からIoT機器への接続が**双方向で成立**すること。
IoT機器からTrusted端末への新規接続が**失敗**すること。

### 段階5: IX自身の管理plane制限

```
ip access-list mgmt-src permit ip src 192.168.10.0/24 dest any
ip access-list mgmt-src permit ip src 192.168.20.0/24 dest any
ssh-server ip access-list mgmt-src
http-server ip access-list mgmt-src
```

現状は`ssh-server ip enable`と`http-server ip enable`があるだけでACL指定が無く、**IoTとGuestから
IXの管理planeへ到達できる**。SSHサーバはsrcのみを判定する（機能説明書 7-2）。http-server側が
destも見る可能性があるため`dest any`にして両方の解釈で安全にしている。

**適用直後に、許可した2ゾーンの両方から確認する。**

- Trustedから`ssh 192.168.20.1` → 成功
- Serverの機器（Apps VMなど）から`ssh 192.168.10.1` → 成功
- IoT/Guestの端末から`192.168.30.1`/`192.168.40.1`のSSHとHTTP → 失敗

### 段階6: 受入試験と保存

4章の行列をすべて実施し、合格を確認してから:

```
exit
write memory
```

## 4. 受入試験の行列

| # | 発信元 | 宛先 | 期待 |
| ---: | --- | --- | --- |
| 1 | Trusted | Server `.10.101` HTTPS/SMB | 成功 |
| 2 | Trusted | Server `.10.11` PVE、`.10.2` ECW、`.10.102`、`.10.103` | 成功 |
| 3 | Trusted | IoT | 成功（今回から許可） |
| 4 | Trusted | **Guest** | **失敗**（初版の穴。必ず試す） |
| 5 | Trusted | Internet | 成功 |
| 6 | Server | Trusted への新規接続 | **失敗** |
| 7 | Server | Trusted が張ったセッションへの応答 | 成功 |
| 8 | Server | IoT | 失敗 |
| 9 | Server | Guest | 失敗 |
| 10 | IoT | Server / Trusted への新規接続 | 失敗 |
| 11 | IoT | Trusted が張ったセッションへの応答 | 成功 |
| 12 | IoT | Guest | 失敗 |
| 13 | Guest | Server / Trusted / IoT | 失敗 |
| 14 | 全ゾーン | Internet | 成功 |
| 15 | 全ゾーン | 自ゾーンでのDHCP取得・更新 | 成功 |
| 16 | Server / Trusted | `ssh 192.168.10.1` / `ssh 192.168.20.1` | 成功 |
| 17 | IoT / Guest | `ssh 192.168.30.1` / `192.168.40.1`、HTTP | **失敗** |
| 18 | tailnet（宅外） | `.10.101`のDNS/HTTPS/SMB | 成功 |
| 19 | tailnet | VLAN 20/30/40のアドレス | **到達しない**（routeを広告していない） |
| 20 | tailnet | exit node経由のInternet | 成功 |
| 21 | — | sFlowが`.10.103`へ届き続けている | 成功 |

denyが効いていることは、カウンタでも確認する。

```
show ip access-list trusted-in
show ip access-list main-out
```

期待: 試験#6を試した直後に`trusted-in`の`deny 10.0/24 → 20.0/24`のヒットが増える。
試験#4を試した直後に`main-out`の`deny 20→40`のヒットが増える。
**ヒットが増えないのに接続が失敗している場合、別の理由で落ちている。**

廃棄ログを見るなら:

```
logging subsystem flt warn
show logging
```

形式: `FLT.008: BLOCK icmp 10.0.0.1 > 10.0.0.254, no match, [IF名] out`
`info`や`debug`は通過パケットも記録してCPU負荷が高い。検証後は`warn`へ戻す。

## 5. Rollback

### 5.1 最短復旧

暗黙denyを起こしているのはBVI20の`out`だけなので、まずこれを外す。

```
configure terminal
interface BVI20
  no ip filter trusted-in 5 out
  exit
```

### 5.2 完全復旧

**必ず上から順に実行する。フィルタのdetachを、ACL定義の削除より先に行うこと。**

```
configure terminal
!
! (1) まずBVI20から両方のフィルタを外す
interface BVI20
  no ip filter trusted-in 5 out
  no ip filter trusted-dyn 5 in
  exit
!
! (2) iot-outを元に戻す（段階4を実施済みの場合のみ）
no ip access-list iot-out permit ip src 192.168.30.0/24 dest 192.168.20.0/24
ip access-list iot-out deny ip src 192.168.30.0/24 dest 192.168.20.0/24
!
! (3) 管理planeを戻す
no ssh-server ip access-list
no http-server ip access-list
no ip access-list mgmt-src
!
! (4) 最後にACL定義を削除する
no ip access-list dynamic trusted-dyn
no ip access-list trusted-trig
no ip access-list trusted-in
!
! (5) 古い判断結果が残らないようキャッシュを流す
clear ip filter dynamic
clear ip ufs-cache
```

(2)の後で`show ip access-list iot-out`を確認し、**戻した`deny 30→20`が末尾の`permit any any`より
前にあること**を必ず見る。後ろに入ると効かない。

`main-out`・`server-out`・`guest-out`は最初から触っていないので復旧不要である。

### 5.3 最終手段

`write memory`していなければ`reload`でstartup-configへ戻る。現在のstartup-configはPhase 4の
VLAN撤去まで反映済みなので、reloadしてもVLAN 11/63は戻らない。

## 6. 投入前に実機で埋める空欄

公式マニュアルに記載が無く、**投入時に実測して確定する項目**。推測で埋めない。

1. **`show ip filter dynamic BVI20`の出力形式。** コマンドの存在はコマンドリファレンス13-4で確認済みだが、
   表示項目の一覧がマニュアルに無い。段階2の直後に取得してこの文書へ貼る。
2. **動的キャッシュがstaticより先に評価されること。** 設定事例集7.3（`out`に全廃棄staticを置きつつ
   `in`の動的で戻りを通す例）と機能説明書2-426から、事例としてはそう動く。**この手順書全体が
   この挙動に依存している。** 段階3の直後、Trusted→Serverの既存セッションが生き残るかが最初の関門。
3. **自装置宛パケットが動的キャッシュを生成するか。** 自装置「発」（DDNS更新）は公式事例で確認できたが、
   自装置「宛」は記載が無い。だから1.6の救済permitと運用ルールを併記している。
4. **`option optimize`がACL行の評価順に影響するか。** 既存4本のACLには付いているが、新設の3本には
   付けていない。行の評価が上から順（first-match）であることは既存ACLの構成と矛盾しないが、
   マニュアルで明示を確認できていない。**段階1と段階4の`show ip access-list`で行順を目視すること。**

第三者の技術ブログに「NEC IXのDynamic ACLは意図せぬ通信まで許可する挙動だった」という報告がある
（検証バージョンの記載なし、公式に該当する制限事項の記述は無い）。**だからこそ4章の#4と#6で
denyのヒットカウント増加まで確認する。**

## 7. 対象外

- **IPv6。** 2026-09-06の採取でIPv6 routeもneighborも0件、BVI/WANにIPv6アドレス無しを確認済み
  （[Phase 4の現在地](../migration/next-session.md)）。したがってIPv4 ACLを迂回する経路は現時点で無い。
  ただし[目標ゾーン設計](target-zones.md)が求めるRA・DHCPv6・forwardingの**明示的な無効化は未実施**で
  あり、この手順書の範囲外とする。別issueで追跡する。
- **`ip dynamic-filter group`によるキャッシュ共有。** NECが「主にSIPダイナミックフィルタを使用する
  一部の環境での利用を想定」と明記しているため採用しない。

## 8. レビュー履歴

- 2026-09-13 初版。NEC公式ver.10.11マニュアルの調査結果に基づく。
- 2026-09-13 Codexによる静的レビューを受けて改訂。修正点:
  - **トリガの末尾`permit any any`を削除**（Trusted→Guestがseq 10のdenyを迂回する穴だった）
  - これに伴い`main-out`の削除をやめ、`main-out`と`server-out`・`guest-out`は無変更とした
  - `iot-out`の変更をBVI20 `out`適用の**後**へ移動（IoT→Trustedが一時的に開く窓を無くした）
  - 完全rollbackで、ACL定義の削除より前にフィルタをdetachするよう順序を明示
  - 受入試験にTrusted→Guest、Server→IoT/Guest、IoT→Guest、tailnetの否定試験、exit nodeを追加
  - 段階5の確認をServerとTrustedの両方からに変更

## 9. 出典

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
