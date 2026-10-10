# NOTES — 運用情報と設計判断ログ

このファイルは引き継ぎ用。使い方・セットアップは [README.md](../README.md)、
初期構築前の設計経緯は [HANDOFF.md](HANDOFF.md) を参照。

## 稼働情報(この個体)

個体固有の値(IP・MAC・シリアルポート)は `LOCAL.md`(gitignore 済み)に記載。

- デバイス IP: ルーターで DHCP 予約して固定する(例: `http://192.168.1.50`)
- WiFi 認証情報: `include/secrets.h`(gitignore 済み)
- テストスクリプトの宛先: `.atom-ip`(gitignore 済み)に実 URL を書くか、環境変数 `ATOM` で指定

## 設計判断ログ

### 承認待ち検知は `Notification` ではなく `PermissionRequest`(2026-08-06)

引き継ぎ資料の指定は `Notification`(matcher: `permission_prompt`)だったが、
実測で「ユーザーがしばらく操作していないときしか発火しない」ことが判明。
`Notification` は通知送信後に発火する副作用イベントで即時性がない。
`PermissionRequest`(matcher: `*`)は agentic loop の同期フロー
(PreToolUse → PermissionRequest → ツール実行)に組み込まれており、
権限確認の瞬間に確実に発火する。

### `PostToolUse` → tool を追加(2026-08-06)

引き継ぎ資料は PostToolUse を意図的に不使用としていたが、それは「ツール完了後も
tool 表示のままが正しいから不要」という理由。承認後に長時間コマンドが走ると
wait の赤が張り付く問題への復帰用途は想定外だったため、追加しても設計意図と矛盾しない。

### LED 表示のチューニング経緯(2026-08-06〜08)

- tool: 黄 250ms 点滅 → 目に痛い → オレンジ 750ms 点滅 → ふわっとさせたい →
  オレンジの呼吸 → オレンジケース越しだと wait の赤と区別不能 → 白の呼吸 →
  紫を試す → 「ラブホみたい」で NG → **白の呼吸で最終確定**
- オレンジを LED で出すときは緑成分をかなり絞る必要がある(CRGB(255,96,0) でも黄色に見える。40 で OK)
- wait: 赤の呼吸 → 目立たせるため **400ms 点滅**に(err の 120ms と速度で区別)
  → さらに二段階化(2026-08-09): **点滅は最初の 30 秒(WAIT_BLINK_MS)だけ、以降は赤の常時点灯**。
  点滅しっぱなしはうるさい一方、常灯が残ることで離席から戻ったときに承認待ちに気づける。
  切替の基準はセッションの wait 開始時刻(waitSince)なので複数セッションでも正しく動く
- done: 緑常灯 3 秒 → 6 秒 → **150ms 点滅 × 6 秒**
- tool / wait はピーク輝度 170 に減光(255 は明るすぎ)。done / err はフル輝度のまま
- idle: 明度 12 の「ごく暗い青」 → ケース越しの視認用に **170(フルの 2/3)** に増光(2026-08-08)
- 白と青の役割を一度反転 → 再反転して元に戻した(2026-08-09)。最終形: **tool = 白の呼吸(ピーク 255)、idle = 青の常灯(128 = 1/2)**
- **オレンジケース越しでは白がピンク〜マゼンタに見える**(2026-08-11、完成品の写真で確認)。
  オレンジの顔料が緑を最も強く吸収するため、白(R+G+B)から緑が抜けて R+B = ピンクになる。
  意図した色ではないが「光るハート」としては可愛いのでそのまま採用し、ドキュメントに補足を入れた。
  同様に idle の青も紫寄りに見える。フィラメントを変えると見え方が変わるので、
  配布先には led-tuning スキルで再調整してもらう前提
- BRIGHTNESS はケース(拡散シェード)前提で 255。裸運用なら 30〜50 に戻す

### 複数セッション対応(2026-08-08)

複数の Claude Code セッションが並行すると状態を上書きし合うため、
ファームウェアでセッション別(最大 8、10 分無更新で失効)に状態を保持し、
`wait > err > done > tool > idle` の優先度で集約表示。
done はセッション単位で 6 秒後に失効するので、他セッション作業中でも完了フラッシュは見える。
`led.sh` が hook の stdin JSON から `session_id` を抽出して `&sid=` で送る。
手動実行(tty)時は `sid=default` になり、実セッションの表示を専有しない。
連打時の取りこぼし対策で curl に `--retry 2 --retry-all-errors` を追加。

### 中断・拒否時の赤張り付き: hook では検知不可能と結論(2026-08-09)

権限ダイアログを No で拒否 / Ctrl+C で中断しても、**どの hook イベントも発火しない**
(v2.1.226 で実測確定)。全 15 イベント(PermissionDenied / PostToolUseFailure /
PostToolBatch / MessageDisplay / Stop / Notification 等)にロガーを仕込んでテストし、
ダイアログ表示の PermissionRequest 以降は完全に無音だった。
`PermissionDenied` はドキュメントどおり「auto mode classifier による拒否」専用で、
手動拒否では発火しない(設定には残してあるが実質未使用)。
`Stop` は正常完了時のみで、中断時は発火しない。

**現状の挙動(仕様として受容)**: 拒否・中断後の赤は
(1) 次のプロンプト入力(UserPromptSubmit → tool)で即解除、
(2) 何もしなければ 10 分のセッション失効(STALE_MS)で idle に落ちる。
wait 専用の短い失効は「離席中の本物の承認待ちが消えてしまう」ため意図的に入れていない。

**再調査するときのデバッグ手法**: stdin の JSON をログに落とすだけのスクリプト
(`date; cat >> ~/.claude/led-events.log`)を全イベントに `async: true` で仕込むと、
何がいつ発火するか確実に観測できる。

### 選択肢ダイアログ(AskUserQuestion)も wait 扱い(2026-08-09)

AskUserQuestion に専用イベントはないが、ツール呼び出しなので PreToolUse が発火する。
`led.sh` 側で「PreToolUse かつ tool_name = AskUserQuestion」なら tool の代わりに wait を送る。
回答すると PostToolUse → tool で自動解除。settings.json の変更は不要(matcher で分けると
`*` と二重マッチして tool/wait が競合するため、led.sh 内で判定するのが正解)。
led.sh は毎回実行されるので変更は再起動不要で即反映される。

### 着弾順逆転の排除: 送信タイムスタンプ(2026-08-09)

権限ダイアログでは PreToolUse(tool)と PermissionRequest(wait)が async でほぼ同時に走り、
curl のリトライも絡むと着弾順が逆転して「ダイアログ表示中なのに白」になることがある
(「同じコマンド連続で赤にならない」として発覚)。
対策: led.sh が送信時刻(ms、perl Time::HiRes)を `&ts=` で付け、
ファームウェアはセッションごとに最後に適用した ts を記憶して**古い ts の更新を棄却**(`stale` 応答)。
ts なし(手動 curl)は常に適用。検証は `./led-test.sh send <state> <sid> <ts>` で
wait(ts大)→ tool(ts小)を送り、state=wait が維持されることを確認。

### サブエージェント・連続 Permission による白上書きの根治(2026-08-09)

実測でわかった事実:
- **サブエージェントのツールイベントは親と同じ session_id で発火する**。メインが
  ダイアログ待ちでも、裏のサブエージェントが tool を送り続けて赤を上書きしていた
- **PermissionRequest の hook JSON には tool_use_id が無い**(v2.1.207 / v2.1.226 で生 JSON を
  3 回観測して確定。実フィールドは session_id / transcript_path / cwd / prompt_id /
  permission_mode / effort / hook_event_name / tool_name / tool_input / permission_suggestions)。
  なお公式ドキュメントは PermissionRequest の入力フィールドを明示しておらず
  「tool_use_id は event-specific」とだけ記載(具体例は PreToolUse のもの)。
  つまり「ドキュメントと矛盾」ではなく「ドキュメントが書いていない部分の実測」。
  tool_use_id は直前(同秒)の PreToolUse には有る
- **割り込みメッセージ(Ctrl+C 後の入力)では UserPromptSubmit が発火しない**ことがある

対策(led.sh 内、実物は repo の `led.sh` を参照):
- PreToolUse ごとに「直近の呼び出し(tool_use_id + tool 名)」を pending ファイルに記録
- ダイアログ表示(PermissionRequest / AskUserQuestion)で marker ファイルを作成。
  PermissionRequest は pending から tool_use_id を補完(tool 名一致を確認)
- marker 存在中の tool イベントは wait に変換(赤を維持)。解除は
  (1) marker と同じ tool_use_id の PostToolUse / PostToolUseFailure、
  (2) UserPromptSubmit、(3) done / err / idle、(4) marker の TTL 10 分
- settings.json に PostToolUseFailure → tool を追加(失敗完了でも解除できるように)

検証: `led-test.sh send` 相当の偽 JSON を led.sh に流し、/ のセッション別内訳
(この対応と同時にファームウェアへ追加)で「ダイアログ中の別イベントで wait 維持 →
該当呼び出しの完了で tool 復帰」を確認済み。

### 手動送信(sid=default)の失効を 2 分に短縮(2026-08-09)

led.sh / led-test.sh をターミナルから手で叩くと `default` セッションとして記録されるが、
10 分間 tool 等に残留して「ターン完了後も白い呼吸が続く(緑→idle に見えない)」事故が起きた。
default だけ失効を DEFAULT_STALE_MS(2 分)に短縮。テスト後は `./led-test.sh off` で
明示的に idle に戻すのが行儀としては正しい。

### 拒否・中断をトランスクリプト監視で検知(2026-08-14)

「No / Ctrl+C はどの hook でも検知不可能」の結論は hook の世界では今も正しいが、
[claude-session-browser](https://github.com/juppeee/claude-session-browser) が
トランスクリプト(JSONL)を tail して状態推測しているのを見て、盲点の補完に採用した。

- 拒否 → `"content": "The user doesn't want to proceed with this tool use..."` の
  tool_result、中断 → `"text": "[Request interrupted by user]"` が**即座に**記録される
  (実セッションのトランスクリプトから実測)
- led.sh がダイアログのマーカー作成時に短命の監視プロセスを spawn し、
  hook JSON の transcript_path の追記分を 1 秒間隔で監視。検知したら marker 削除 + idle 送信
- **構造的マッチ**が重要: 会話文中で同じ文字列を引用すると JSON 内では `\"` に
  エスケープされるため、`"content": "The user...` のようにフィールド構造ごと
  マッチすれば誤発火しない(偽陽性テスト済み)
- 監視はマーカー消失(通常経路で解決)か 10 分(マーカー TTL と同じ)で自然終了。
  常駐デーモンなし
- 文字列は Claude Code のバージョンで変わり得るベストエフォート。取りこぼしても
  従来の保険(次プロンプト / 10 分 TTL)がそのまま効く

なお同ツールの「トランスクリプトだけで全状態を推測」への全面移行はしない。
permission prompt はトランスクリプトに記録されず(同ツールの README にも明記)、
承認待ちの検知は hooks(PermissionRequest)の方が確実なため。hooks 主 + 監視補完。

### 自動消灯(2026-08-06)

最後の HTTP リクエストから 30 分(`OFF_MS`)で完全消灯、次のリクエストで復帰。
`STALE_MS`(セッション失効)とは別のタイマー(`lastRequest`)。

## ケース設計(3D プリント、Clawd 風キャラ)

- 胸のハート窓のデッドフロント構造: オレンジ PLA 薄皮 **0.4mm** を本体と一体印刷
  (実測で idle の暗い青含む全色視認 OK、2026-08-08)+ LED からの空気層 **8〜10mm**
  (目安: 窓幅の半分以上)。白拡散板も検討したが、0.4mm 薄皮のみで全色見えたため**最終的に不採用**
- 目は別ジョブで印刷して接着(AMS 不要にするため)。ケーブルは四方の切り欠きでどの方向にも出せる
- お腹と背中の 2 パーツ構成で、**6mm×3mm 円形磁石 × 4 個**で留める(ネジ・接着なし、書き込み時に開けられる)
- 遮光したい壁は 1.5mm 以上。窓の周囲はペリメータを増やしてソリッドにしないとインフィルが透ける
- 白 PLA は最も光を通す色 = 白試作で OK ならオレンジ本番はより遮光される
- オレンジ PLA は色フィルタとして働く(緑・青を減衰)。tool を白にしたのはこのため
- ハート上部の谷は幅 1.5mm 以上ないと潰れる
- ボタン穴なし(書き込み時はケースから外す運用)。手元では L 字 USB アダプタで立てているが、アダプタの個体差で合わないものがあるため公開文面には書かない
- 帽子デザイン案は AMS がないため見送り

## 開発の落とし穴

- `pio device monitor` は TTY 必須でバックグラウンド実行不可。代わりに pyserial で
  `dtr = False` / `rts = False` を設定してからポートを開いて読む
  (PlatformIO 同梱の python: `/opt/homebrew/Cellar/platformio/*/libexec/bin/python`)
- `platform = espressif32@6.9.0` 固定は Espressif が PlatformIO 公式プラットフォームの
  保守を終了しているため。最新にすると Arduino core 3.x との噛み合わせでビルドが通らないことがある
- FastLED も `3.7.8` に固定している。`^3.6.0` 指定だと最新版(確認時点で 3.10.6)が入り、この platform
  (Arduino core 2.0.17) ではビルドは通るが LED が更新されなくなる(Web サーバーは応答し続けるので
  `led-test.sh status` では正常に見える)。上げる場合は `led-test.sh rgb` で色が変わることを目視確認する
- `loop()` に `delay()` を入れない(handleClient が止まる)。点滅は全て `millis()` 差分で描画
- 起動時の WiFi 接続中インジケータは紫の常灯(tool の白い呼吸とは動きで区別)
