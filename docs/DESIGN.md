# shiibar 設計書

> menu bar agent status & jump for Claude Code + iTerm2

## 1. 目的

Claude Code のエージェント状態(idle / working / blocked / done)を macOS メニューバーで常時可視化し、
通知やドロップダウンのクリックひとつで該当する iTerm2 のタブへジャンプできるようにする。
併せて、状態変化をスクリプトから利用するための CLI(`wait` 等)を提供する。

### 設計原則

1. **特化する**: Claude Code 専用・iTerm2 専用。speculative generality は書かない
2. **意味の局所化**: 外部依存(iTerm2 の ID 形式、AppleScript)を知るコードは `shiibar-client` の
   iterm モジュール一箇所に閉じ込める。抽象化レイヤーは作らないが、汚染も広げない
3. **メニューバーは読み取り + focus のみ**: 破壊的・対話的な操作はすべて CLI に置く
4. **表示クライアントは全部 subscriber**: daemon に対して対等。増減してもコアに手が入らない

### 非スコープ(作らないもの)

- tmux 対応(通常モードも -CC も)
- Claude Code 以外のエージェント対応
- サイドバー TUI / iTerm2 Toolbelt
- worktree の作成・削除統合(作成はユーザーのシェル関数で足りる)
- リモート / SSH 対応
- 設定ファイル(§8.9。定数は §9 の表、変更手段は環境変数 2 つのみ)

バックログ(シグナルが来たら検討): `cleanup`(worktree 畳み)、他エージェント、
launchd 常駐(§8.8)、PreToolUse 連携による blocked 解除の厳密化(§8.7)、
表示・通知の磨き込み(§8.10)。

各項目の「なぜ作らないか」と再検討の条件は **§8 決定の記録** にある。実装中に迷ったらまずそちらを読むこと。

## 2. アーキテクチャ

```
Claude Code hooks ──(Unix socket, NDJSON)──► shiibard
                                               │ 状態保持 + イベント配信
                        ┌──────────────────────┼──────────────────────┐
                        ▼                      ▼                      ▼
                  メニューバーアプリ        shiibarctl            (将来の subscriber)
                  (SwiftUI, menu bar)   list/wait/watch/focus/…
```

- **target は不透明文字列**。中身は `$ITERM_SESSION_ID` だが、shiibard は解釈せず保持・転送するだけ。
  意味を知るのは shiibar-client の iterm モジュールと、target を生成する `shiibarctl report` のみ
- 状態ディレクトリ: `~/.local/state/shiibar/`(起動時に 0700 で作成)。
  環境変数 `SHIIBAR_STATE_DIR` で上書き可(テスト・並列実行用)。
  中身: `shiibard.sock` / `state.json` / `sessions.jsonl` / `shiibard.log` / `last_focus`
- プロトコル: 行区切り JSON(NDJSON)。リクエスト/レスポンス + subscribe ストリーム

## 3. 状態モデル

状態は `idle`(起動済み・未依頼)/ `working`(実行中)/ `blocked`(ユーザーの番)/ `done`(完了直後・結果を見てほしい)。
`done` と `idle` は区別する(通知・表示の質に直結する)。

### 3.1 遷移表(イベント × 現状態)

「—」は状態変更なし(last_seen 更新のみ)。「登録(x)」は未登録 target のエントリ新規作成。

| イベント(分岐条件)                                  | 未登録    | idle    | working | blocked | done    |
| ---------------------------------------------------- | --------- | ------- | ------- | ------- | ------- |
| SessionStart(source: startup / clear / resume)        | 登録(idle) | idle    | idle    | idle    | idle    |
| SessionStart(source: compact)                         | 無視      | —       | —       | —       | —       |
| UserPromptSubmit                                      | 登録(working) | working | working | working | working |
| PostToolUse / PostToolUseFailure                      | 登録(working) | —       | —       | working | —       |
| Notification(permission_prompt / agent_needs_input / elicitation_dialog / **未知種別**) | 登録(blocked) | blocked | blocked | blocked | blocked |
| Notification(idle_prompt)                             | 無視      | —       | blocked | —       | —       |
| Notification(auth_success / elicitation_complete / elicitation_response / agent_completed) | 無視 | — | — | — | — |
| Stop(background_tasks 残あり)                         | 登録(working) | working | working | working | working |
| Stop(background_tasks 空)                             | 登録(done) | done    | done    | done    | done    |
| SessionEnd                                            | 無視      | 削除    | 削除    | 削除    | 削除    |
| seen(focus 成功時に client が送る。§4.4)              | 無視      | —       | —       | —       | idle    |

この表がそのままテーブル駆動テストの仕様である。補足:

- **Notification 分岐の意図**: 未知種別は blocked に倒す(見逃しより誤報を許容)。
  `idle_prompt`(放置アラート)を無条件 blocked にすると done/idle の放置セッションが赤バッジ化して
  信号が劣化するため、working からのみ blocked にする。elicitation_* の実際の意味は M1 で実ログ検証(§7-2)
- **PostToolUse は blocked 解除用**: 並行ツール実行による早期解除のレースは既知の制約として許容する(§8.7)
- **SessionStart(compact)**: auto-compact 後の再開で idle に落とさないための分岐
- **未登録 target**(daemon 再起動後の途中参加): 遷移を生むイベントのみ登録し、
  「無視」行のイベント(no-op Notification / SessionEnd / compact / idle_prompt)では登録しない
- **同値セルの扱い**(例: working 中の UserPromptSubmit → working): `since` は**状態が変わったときのみ**更新する。
  したがって同値遷移は「—」と観測上同じ(session_id / cwd / task / message も不変なら配信しない。
  変わっていれば §4.2 の規則どおり配信される。§4.2 が優先)。表で書き分けているのは
  「未登録時に登録するか」と遷移の意図を明示するため。テストは結果状態を assert する

### 3.2 エントリの属性と削除

- エントリ属性: `target`(プライマリキー)/ `status` / `session_id` / `cwd` / `since`(現在の状態に入った時刻)
  / `last_seen`(最後に report を受けた時刻)/ `task`(最後の UserPromptSubmit の prompt 先頭 80 文字。表示用)
  / `message`(blocked の理由 = Notification の message。blocked 以外へ遷移したら消す)。
  同一 target への report は `session_id` / `cwd` / `task` / `message` を上書きする(§7-3)
- **時刻はすべて daemon の時計**(epoch 秒)。report の `ts` は表示用で、順序判定・stale 判定には使わない。
  daemon 内の時計は注入可能にする(stale テストのため)
- **stale 削除**: last_seen からの経過が閾値(一律 24h)を超えたエントリを削除し `agent_removed` を配信する。
  スイープは 60 秒周期タイマー + daemon 起動時に実行する(状態別の短い閾値は §8.10)
- **手動削除**: `shiibarctl remove <selector>` で幽霊エントリ(SessionEnd 取りこぼし等)を消せる(§4.4)

## 4. コンポーネント

### 4.1 hooks(`hooks/`)

- `hooks/report.sh`: stdin の hook JSON をそのまま `shiibarctl report <event>` に渡すだけの薄いスクリプト
  (`shiibarctl` が PATH にない場合も黙って成功終了)
- ペイロードの抽出(`session_id` / `transcript_path` / `cwd` / `hook_event_name` / `notification_type` /
  `source` / `message` /(UserPromptSubmit 時)`prompt`(先頭 80 文字に切り詰め)/(Stop 時)`background_tasks`)、
  target の生成、socket への書き込みはすべて `shiibarctl report` 側(Rust)で行う。外部ツール(nc / jq)依存なし
- **target の生成規則**: `$ITERM_SESSION_ID` があればその値。なければ(VS Code ターミナル等)
  `session:<session_id>` を target にする(空 target への衝突を防ぐ。focus は自然に失敗する)
- shiibard 不在時は **黙って成功終了**する(hooks が Claude Code の動作を阻害しないこと。タイムアウト 1 秒)。
  切り分けは `shiibarctl doctor` で行う(§4.4)
- `hooks/settings-snippet.json`: `~/.claude/settings.json` に貼る hooks 設定
  (SessionStart / UserPromptSubmit / PostToolUse / PostToolUseFailure / Notification / Stop / SessionEnd
  → いずれも `report.sh <event>`)

### 4.2 shiibard(`crates/shiibard`)

Rust 製 daemon。tokio + Unix socket。

#### リクエスト種別

```jsonc
// hooks からの報告。クライアントは 1 行書いて close する。daemon はレスポンスを返さない
// (fire-and-forget。EOF を接続終了として扱う)
{"cmd":"report","event":"Notification","notification_type":"permission_prompt","message":"Bash: cargo test",
 "target":"w0t0p0:D2DA6A1F-…","session_id":"…","cwd":"/path","transcript_path":"…","ts":1751600000}
{"cmd":"report","event":"UserPromptSubmit","prompt":"focus の AppleScript を実装して",
 "target":"…","session_id":"…","cwd":"…","transcript_path":"…","ts":1751600060}
{"cmd":"report","event":"Stop","target":"…","session_id":"…","cwd":"…","transcript_path":"…",
 "background_tasks":[{"id":"…","status":"running"}],"ts":1751600123}

// 現在の全エージェント状態
{"cmd":"list"}
// → {"ok":true,"agents":[{"target":"…","status":"blocked","session_id":"…","cwd":"…",
//      "task":"…","message":"…","since":…,"last_seen":…}]}

// イベント購読(接続を保持し、1 行ずつ push)
{"cmd":"subscribe"}
// → 最初に {"event":"snapshot","agents":[…]} を 1 行 push(初期スナップショット)。以降:
//    {"event":"status_changed","agent":{…}}   … status / session_id / cwd / task / message のいずれかが変わったとき
//    {"event":"agent_removed","target":"…"}   … SessionEnd / stale / remove
//    (last_seen だけの更新では配信しない)

// エントリの手動削除・既読化(shiibarctl remove / focus 成功時の seen)
{"cmd":"remove","target":"…"}   // → {"ok":true}(未登録でも ok)
{"cmd":"seen","target":"…"}     // → {"ok":true}(未登録でも ok)。done のときのみ idle に落とす(§3.1)

// graceful 終了(メニューバーアプリの Quit 時に使う。state.json は変異ごとに保存済み)
{"cmd":"shutdown"}              // → {"ok":true} を返してから終了

// 過去セッション一覧(resume 用)・daemon 自己情報(doctor 用)
{"cmd":"sessions"}  // → {"ok":true,"sessions":[{"session_id":…,"cwd":…,"last_status":…,"last_seen":…}]}(last_seen 降順)
{"cmd":"info"}      // → {"ok":true,"version":"…","started_at":…,"last_report_at":…}
```

#### プロトコル契約

- 接続は 1 リクエスト 1 レスポンス(`report` はレスポンスなし、`subscribe` のみストリームとして接続維持)
- 不正な JSON・未知の `cmd` には `{"ok":false,"error":"…"}` を返して接続を閉じる
- **処理順序**: daemon は接続の accept 順・受信順に直列で処理する。観測可能な順序は subscribe ストリームが定義する
  (テストは watch の出力列を assert すればよい。sleep 同期は不要)
- **前方互換**: クライアントは未知の `event` / `status` / フィールドを無視すること(バージョン番号は設けない)
- 送信が詰まった subscriber は切断され得る(実装は bounded channel。容量は実装定数でありプロトコル契約ではない。
  クライアントは再接続すれば snapshot で回復する)

#### 運用

- **起動シーケンス**: socket ファイルが既に存在する場合、接続を試行 → 応答があれば二重起動として即終了、
  応答がなければ stale socket として unlink してから bind
- **状態スナップショット**: 状態を変異させる処理(report(**last_seen のみの更新を含む**)/ remove / seen /
  stale スイープ)のたびに全状態を `state.json` へ atomic に上書き(tmp + rename)。起動時に読み込んで復元する(daemon 再起動で blocked の存在が消えないこと。
  復元後の stale 判定は通常規則に任せる。last_seen を含めて永続化するので、生きている working が
  再起動直後のスイープで誤削除されることはない)
- **セッション履歴**: SessionStart / Stop / SessionEnd 時に `sessions.jsonl` へ 1 行追記。
  行の形式は `sessions` 応答と同じ `{session_id, cwd, last_status, last_seen}`(last_status は §3 の 4 値。
  SessionEnd 時は直前の状態)。読み込み時に session_id で重複排除(最新優先)。
  起動時に 1000 行を超えていたら重複排除して書き直す
- **ログ**: stderr に 1 行 1 イベントで出力(launchd 経由では `shiibard.log` にリダイレクト)。
  レベルは `SHIIBAR_LOG`(error / info / debug、既定 info)。report 受信は debug、状態遷移と削除は info で記録する
- **ライフサイクル**: daemon はメニューバーアプリが起動・停止を管理する(launchd には常駐させない。§8.8)。
  開発時および M4 以前のドッグフーディングは `shiibard --foreground` で手動起動する。
  daemon 不在中の report は失われる(許容。§8.8)

### 4.3 shiibar-proto / shiibar-client(`crates/shiibar-proto`, `crates/shiibar-client`)

- `shiibar-proto`: メッセージ型(serde)と NDJSON codec。daemon / ctl で共有
  (メニューバーアプリは Swift なので共有しない。プロトコル = NDJSON 自体を安定境界とする)
- `shiibar-client`: socket 接続、list / subscribe / wait のクライアント実装と、**iterm モジュール**
  - `wait` は subscribe 1 本で実装する(最初に snapshot が来るので、別途 list を叩く必要はない)
  - iterm モジュール(iTerm2 の知識はここにのみ存在させる)。
    **テスト分離**: AppleScript ソースの生成と osascript 出力のパースは純関数として切り出し、
    osascript プロセス実行部だけを差し替え可能にする
    - `focus(target)`: target の `:` 以降の UUID を取り(形式 `wNtNpN:UUID` は 2026-07-04 検証済み)、
      AppleScript で iTerm2 の windows→tabs→sessions を走査して一致セッションの tab を select、
      window を前面化、`activate`。一致なし(`session:` フォールバック target 含む)は「該当なし」。
      **iTerm2 が起動していなければ起動せずに「該当なし」を返す**(`tell app … to activate` を走査成功後まで遅延)
    - `focused()`: iTerm2 が最前面アプリのとき、前面 window の current session の target を返す。
      iTerm2 が前面でなければ「なし」
    - `open_tab(cwd, cmd)`: 新規タブを cwd で開いてコマンドを実行(resume 用)。こちらは iTerm2 を起動してよい
    - osascript の TCC(オートメーション)権限エラーは「該当なし」と区別して呼び出し元に返す

### 4.4 shiibarctl(`crates/shiibarctl`)

```
shiibarctl report <event>     # hooks 専用: stdin の hook JSON を整形して daemon に送信(M1 で前倒し実装)
shiibarctl list [--json]      # 非 --json は「状態 / ラベル / 経過時間 / target」の整列テキスト
shiibarctl wait <selector> --status done|blocked|idle|working [--timeout SEC]
shiibarctl watch              # subscribe のイベントを行 JSON で標準出力へ
shiibarctl focus <selector>   # ジャンプ。成功時: 移動前の前面 target を last_focus に保存し、daemon に seen を送る
shiibarctl focus -            # last_focus に戻る(ジャンプ→対応→元の作業へ、の帰り道)。
                              # `focus -` 自身も移動前の target を last_focus に保存する(cd - と同じトグル)。seen も送る
shiibarctl focused            # 前面 iTerm2 セッションの target を出力(なければ exit 2)
shiibarctl remove <selector>  # 幽霊エントリの削除
shiibarctl resume             # sessions から選択 → 履歴の cwd で新規 iTerm2 タブを開き claude --resume <id>
shiibarctl doctor             # 診断(下記)
```

- **selector**: target の完全一致、または `.`(カレントディレクトリと cwd が一致するエージェント。
  UUID の手打ちを不要にする)。cwd 部分一致などの拡張は実運用のシグナル待ち(§8.10)
- **exit code(全サブコマンド共通)**: 0 成功 / 1 接続・内部エラー(daemon 不在含む。stderr に理由) /
  2 該当なし(wait では対象消滅。理由は stderr に出す) /
  3 osascript 権限(TCC)エラー / 124 wait タイムアウト。
  **例外は `report` のみ**: hooks を阻害しないため、daemon 不在・タイムアウトを含め常に exit 0(§4.1)
- **wait の selector 解決**: 開始時に 1 回解決し、以降はその target を追う(未登録なら出現を待つ)。
  `--timeout` 省略時は無限に待つ
- **resume**: fzf があれば fzf、なければ番号選択のプロンプト。実行中(list に存在する)セッションは候補から除外する
  (`claude --resume` の二重起動防止)。履歴の cwd が消えていれば警告して `$HOME` で開く
- **doctor**: 以下を順に検査して人間向けに報告する —
  socket 疎通(`info` の応答)/ daemon の version・last_report_at / hooks 設定の有無
  (`~/.claude/settings.json` に report.sh が含まれるか)/ `shiibarctl` が PATH にあるか /
  osascript の TCC 権限(無害な iTerm2 走査を 1 回試す)。「通知が来ない」の切り分けはまずこれを実行する

### 4.5 メニューバーアプリ(`app/`)

SwiftUI(macOS 13+、`MenuBarExtra` または `NSStatusItem`)。tray title でロールアップ常時表示、メニューが一覧、通知クリックで focus。

- **見た目の正は `docs/menubar-design.html`**(2026-07-04 確定)。トレイは塗りなしの円形枠線 + 上下左右 4 ランプ
  (上=blocked / 右=working / 下=done / 左=idle)の点灯/消灯式。該当エージェントがいれば色で点灯、
  いなければ輪郭のみ。アイコンは枠線だけ(塗りがないため idle の灰と混ざらない)で、ランプは枠線に直接接する(隙間なし)。
  エージェント 0 台は全消灯(構造は常に不変)。描画は NSImage 合成で状態変化ごとに描き直す。本節は挙動のみを規定する
- **daemon 接続**: `NWConnection` で UDS に接続し、subscribe の行 JSON を `JSONDecoder` で読む。
  切断時(daemon 再起動・スリープ復帰)は 1 秒から倍々・上限 30 秒のバックオフで再接続(snapshot で状態回復)。
  未知の event / status は無視する(前方互換)
- **ドロップダウン**: 行は 2 行 — 1 行目 = ラベル、2 行目 = 状態 + 経過時間 + 作業内容
  (blocked は `message`(許可内容)、それ以外は `task`(最後の依頼文)。§3.2)。
  並び順は blocked → working → done → idle、グループ内は登場順で安定(開くたびに並びが変わらない)。
  クリックで `shiibarctl focus <target>` を subprocess 実行。`agent_removed` で行を消す。
  先頭に「← 戻る」(= `shiibarctl focus -`)を置く
- **表示ラベル**: cwd をホーム配下なら `~` 起点にし、末尾 2 要素を表示(足りなければあるだけ)。
  ラベルの重複はそのまま表示する(並び順が安定していれば足りる。区別の工夫は §8.10)。
  git/worktree の概念は持たない(文字列整形のみ。`repo/branch` に見えるのは worktree のディレクトリ名の偶然)
- **デスクトップ通知**: `UNUserNotificationCenter`。`blocked` 遷移時と `done` 遷移時に発火し、クリックは delegate で受けて focus
  - 遅延通知: 3 秒後にタイマー発火した時点で**最新状態を再確認**して、まだ同状態なら通知(スリープ跨ぎでも安全)
  - **通知済み管理**: アプリは (target, since) 単位で通知済みを記録する。再接続時の snapshot に含まれる
    blocked / done も通知対象(切断中の遷移を取りこぼさない)だが、通知済みの同一状態には再通知しない
    (スリープ復帰のたびに既知の blocked が鳴り直さない)
  - 前面抑制: 通知直前に `shiibarctl focused` を叩き、対象 target が前面ならその通知は出さない
  - 通知の掃除: 状態変化・`agent_removed`・focus 時に該当 target の配信済み通知を `removeDeliveredNotifications` で消す
    (古い通知をクリックして無関係なタブに飛ぶ事故を防ぐ)
- **異常の可視化**(黙って機能停止しない): 以下はドロップダウン先頭に警告行を常設表示する —
  daemon と切断中(再接続バックオフ中。古いスナップショットを正常と誤認させない)/
  通知権限が denied / focus が TCC エラー(exit 3)を返した
- **daemon のライフサイクル管理**: アプリ起動時に socket へ接続し、応答があれば**既存 daemon にアタッチ**する
  (アプリのクラッシュ等で残った orphan daemon もここで回収される。daemon 側の二重起動防止は §4.2 の
  起動シーケンスが担う)。応答がなければ同梱の `shiibard` を spawn し、バックオフ再接続で繋ぐ。
  アプリ終了(Quit)時は `shutdown` を送って daemon も止める。アプリ自体は Login Items に登録(install スクリプトが設定)
- 配布はしない(当面自分専用)。通知には bundle identifier 付きの .app が必要なため、
  Swift Package(executable)+ .app 化 & ad-hoc 署名のビルドスクリプトでローカルインストールする。
  ad-hoc 署名は再ビルドで通知権限がリセットされ得るため、install スクリプトで安定した署名 ID を使う
- **同梱**: `shiibard` / `shiibarctl` は .app の `Contents/Helpers/` に同梱する。アプリは同梱バイナリを
  絶対パスで呼ぶ(PATH 非依存)。install スクリプトが `~/.local/bin/shiibarctl` → 同梱バイナリへの
  シンボリックリンクを張り、hooks や手動 CLI は PATH 経由で同じ実体を使う(**アプリを入れれば全部入る**)

## 5. リポジトリ構成(monorepo)

```
shiibar/
├── Cargo.toml              # workspace
├── crates/
│   ├── shiibar-proto/
│   ├── shiibar-client/
│   ├── shiibard/
│   └── shiibarctl/
├── app/                    # SwiftUI メニューバーアプリ(Swift Package + .app 化スクリプト)
├── hooks/
│   ├── report.sh
│   └── settings-snippet.json
├── scripts/
│   ├── install.sh          # M2: バイナリ配置 + hooks 案内 / M4 で .app 化(shiibard・shiibarctl 同梱)+ CLI symlink + Login Items
│   ├── uninstall.sh
│   └── dev-reload.sh       # 開発中の daemon / app 差し替え(ドッグフーディング用)
├── fixtures/               # 実 hook JSON の採取物(M1 で採取・コミット。統合テストが再生する)
├── docs/
│   ├── DESIGN.md           # 本書(挙動の正)
│   └── menubar-design.html # メニューバー確定デザイン(見た目の正)
├── CLAUDE.md
├── LICENSE-MIT / LICENSE-APACHE
└── README.md
```

ライセンス: MIT OR Apache-2.0(デュアル)。

## 6. マイルストーン

各 M の完了条件は「自動テスト」と「実機スモーク(手動)」に分ける。

| M   | 内容                                               | 自動テスト                                                   | 実機スモーク                                   |
| --- | -------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------- |
| M1  | proto + shiibard(report/list/subscribe/remove/seen/info/shutdown、state.json 復元、ログ)+ `shiibarctl report` + hooks | 遷移表(§3.1)のテーブル駆動テスト。fixtures 再生 → subscribe 出力列が期待と一致。daemon 再起動で状態復元 | 実セッションの遷移を watch で観測。実 hook JSON を fixtures/ に採取 |
| M2  | shiibar-client + shiibarctl(list/watch/wait/focus/focused/remove/doctor)+ install.sh(バイナリ + hooks。daemon は手動起動、.app は M4) | exit code 系統(wait: 0/1/2/124、focus: 0/1/2/3)。selector 解決。iterm モジュールの純関数部 | `wait --status done && say done` が動く。focus で該当タブが前面に来る。doctor が全項目 green |
| M3  | resume(sessions 保存 + `shiibarctl resume`)        | sessions.jsonl の重複排除・compaction。実行中セッションの除外 | daemon 再起動後も履歴から `claude --resume` で復帰できる |
| M4  | メニューバーアプリ                                 | (UI は手動中心)                                              | アプリ起動で daemon 起動・既存 daemon へのアタッチ・Quit で daemon 停止。ロールアップ表示・ドロップダウン focus・「戻る」。blocked / done 通知(遅延・前面抑制: blocked 中に該当タブへフォーカスして通知が出ないこと)。focus で配信済み通知が消えること。切断中・権限 denied の警告行 |

M2 完了時点で日常投入を開始し、以降はドッグフーディングしながら M3/M4 を進める。

## 7. リスク・要検証事項(実装前に潰す)

1. **`$ITERM_SESSION_ID` の形式と AppleScript の session id の対応** — ✅ 検証済み(2026-07-04)。
   形式は `wNtNpN:UUID`、AppleScript の `id of session` は裸の UUID で、素の iTerm2 タブでは UUID 部が一致する。
   (参考: tmux 内では env が凍結され一致しないことも確認済みだが、tmux は非スコープなので問題にならない)
2. **hook イベントのペイロード仕様** — ✅ 公式ドキュメントで確認済み(2026-07-04):
   Stop の `background_tasks` は v2.1.145+ で実在、Notification は `notification_type` で 8 種
   (permission_prompt / idle_prompt / auth_success / elicitation_dialog / elicitation_complete /
   elicitation_response / agent_needs_input / agent_completed)、権限拒否時は `PostToolUseFailure`、
   SessionStart に `source`、SessionEnd に `reason`。
   **M1 の残検証**: 実ログとの突き合わせ。特に (a) `idle_prompt` の発火条件と対象状態、
   (b) elicitation_* の実際の意味(§3.1 の分類の妥当性)、(c) `background_tasks` の実ペイロード形式
3. **同一 iTerm2 タブ内での Claude Code 再起動**: target(ITERM_SESSION_ID)は同一で session_id が変わる。
   target をプライマリキーにし、session_id は属性として上書きする(§3.2)

## 8. 決定の記録

実装中に「対応した方が親切では」と思っても、以下は議論済みの意図的な決定である。覆す場合は再検討の条件を満たしていることを確認する。

### 8.1 tmux に対応しない

- tmux を使っていた理由は (1) `-CC` によるネイティブ UI と (2) Agent Teams の pane 分割表示だったが、(2) は使わなくなり、(1) の永続化価値はローカル運用では iTerm2 の Session Restoration でほぼ代替できる
- tmux 対応は設計の複雑さの主因だった: 複数セッション×アタッチ状態の分岐、デタッチ中の `-CC` アタッチ起こし、tmux-resurrect 連携、`select-window`+ウィンドウ前面化の二段ジャンプ。落とすことで focus が一本道になった
- 技術的な補足(2026-07-04 検証): tmux 内では `$ITERM_SESSION_ID` が tmux サーバー起動時の値で凍結され実セッションと一致しないため、tmux 対応する場合は target を `$TMUX_PANE` に切り替える必要があった。`-CC` では `tmux select-window` で iTerm2 のタブが切り替わることまでは実験で確認済み
- なお `-CC` プロトコルの互換実装(tmux 以外のサーバー)は存在しないため、「tmux 抜きで -CC の UX」という選択肢はそもそもない
- **再検討の条件**: Agent Teams の pane 分割表示を日常的に使う運用に戻ったとき。その場合も target が不透明文字列なので、hooks の報告値と focus 関数の追加で対応できる(コアは無変更)

### 8.2 抽象化レイヤーを作らない

- エージェント抽象(trait/アダプタ層)、ターミナル抽象、target の構造化(`{kind, id}`)はすべて不採用。1 例しかない段階の抽象は 2 例目の実物と合わずに壊れる
- 代わりに「意味の局所化」で移行コストを抑える: target を解釈するのは iterm モジュールのみ、hook イベント名を知るのは report の正規化のみ。状態語彙(idle/working/blocked/done)だけはエージェント非依存に定義し、subscriber には hook の語彙を漏らさない
- **再検討の条件**: 2 つ目のエージェント/ターミナルに実際に対応する PR を書くとき。そのときに初めて、実物 2 例から共通部分を抽出する

### 8.3 サイドバー(TUI / Toolbelt)を作らない

- TUI サイドバーは既存プラグイン(hiroppy/tmux-agent-sidebar 等)の領分で、tmux を落とした今は前提も消えた
- iTerm2 Toolbelt は Python API ランタイム常駐と API 追従の保守コストに対し、得られる差分が「クリックなしの詳細一覧」のみ。メニューバー title のロールアップ常時表示で価値の大半を代替する
- **再検討の条件**: 「ドロップダウンを開いて眺めるだけで閉じる」を 1 日に何度も繰り返している自覚が出たとき。その場合も `shiibarctl watch` の行 JSON を加工する形で軽く作れる

### 8.4 メニューバーに focus 以外の動詞を置かない

- worktree 削除等の破壊的・対話的操作は確認フローが必要で、メニューバーの 1 クリックに向かない。動線上も「結果をターミナルで確認した後」に片付けるため、CLI が自然な置き場所(幽霊エントリの `remove` も CLI に置いた)
- 例外は「← 戻る」(focus の一種であり読み取り+ジャンプの範囲内)
- **判断基準の一般形**: 迷ったら、破壊的・対話的なら CLI、読み取りとジャンプならメニューバー

### 8.5 メニューバーアプリは Tauri ではなく SwiftUI

- 決め手は通知クリック: Tauri v2 では macOS で通知クリックイベントが取れるか要検証(取れない場合のフォールバック設計まで必要)だったが、native なら `UNUserNotificationCenter` の delegate で確実に取れる。リスク項目が一つ消えた
- このアプリの UI はメニューバーと通知だけで webview を描く場面がなく、macOS 専用と決めた時点で Tauri のクロスプラットフォーム性は何も買っていない。常駐アプリとしてのフットプリントも native が軽い
- 代償は Rust クレート(proto/client)を共有できないことだが、subscribe は「UDS の行 JSON を読む」だけ(`NWConnection` + `JSONDecoder`)、focus は `shiibarctl focus` の subprocess 呼び出しで足りる。設計原則 4「表示クライアントは全部 subscriber」のとおり、プロトコルが安定境界として機能する
- **再検討の条件**: 他 OS 対応や広い配布が必要になったとき。その場合も daemon / プロトコルは無変更で、subscriber を作り直すだけ

### 8.6 hooks は `shiibarctl report` 経由で送る(nc を使わない)

- シェルは Unix ソケットに直接書けないため外部コマンドが必要になるが、`nc -U` は BSD/GNU 系で挙動が揺れる。タイムアウト 1 秒・daemon 不在時は黙って成功、という要件は Rust 側で制御する方が確実
- `report.sh` は stdin を `shiibarctl report <event>` に渡すだけの薄いスクリプトになり、JSON 抽出(jq)も不要。プロトコルの知識は shiibar-proto に一本化される
- 代償として `shiibarctl` のバイナリ(report サブコマンドのみ)が M1 に前倒しになるが、ソケットに 1 行書くだけなのでコストはほぼゼロ

### 8.7 blocked 解除は PostToolUse で行う(既知のレースを許容)

- 許可ダイアログ表示中に、並行実行中の別ツールや subagent の PostToolUse が届くと、ユーザーが応答する前に working へ戻る誤解除があり得る
- 厳密に潰すには PreToolUse を hook して tool_use_id を対応付ける必要があり、hooks の複雑さが一段上がる。個人用ツールとしては誤解除の頻度を見てから判断する
- **再検討の条件**: ドッグフーディングで「blocked が勝手に消えて許可待ちを見逃した」が体感で気になったとき。対策方向は PreToolUse との対応付け

### 8.8 daemon のライフサイクルはメニューバーアプリに従属させる(launchd に常駐させない)

- アプリ起動で daemon 起動(既存がいればアタッチ)、アプリ終了で daemon も終了。「アプリを止めている間は監視も止まる」を意図的な仕様とする(唯一のユーザーが望んで止めているのだから、裏で動き続ける必要がない)
- これにより launchd plist / KeepAlive / socket activation の管理が丸ごと消え、インストールは「.app 一式(daemon・CLI 同梱)」に寄る。アプリのクラッシュで残った orphan daemon は次回起動時のアタッチで回収される
- 代償: アプリ(= daemon)不在中に発火した hook の report は失われる。state.json 復元により、失われるのは不在中の遷移のみ
- **再検討の条件**: アプリを起動せず CLI(wait / watch)だけで常用したくなったとき。そのときは launchd plist または `shiibard start`(自己デーモン化)を足す

### 8.9 設定ファイルを作らない

- 定数は §9 の表に集約し、v1 の変更手段は環境変数 2 つ(`SHIIBAR_STATE_DIR` / `SHIIBAR_LOG`)のみ。
  ユーザーは作者本人だけであり、チューニングしたくなったらコードを直せばよい
- 「既定」と書かれた値は「実装上の定数」の意味であり、設定可能性を約束しない
- **再検討の条件**: 同じ定数を 3 回以上変えたくなったとき、その定数だけ環境変数化する

### 8.10 v1 から意図的に削った磨き込み

レビューで提案されたが「初週のドッグフーディングで実害が出ない」と判断して落としたもの。実害が出たら足す。

- **ラベル重複の自動解決**(階層を増やす / session_id 付与) — 再検討: 同名ラベルで別エージェントに誤ジャンプしたとき
- **stale 閾値の状態別化**(死んだ working の早期掃除) — 再検討: 死んだ working が tray のカウントを恒常的に濁したとき(それまでは `remove` で手動掃除)
- **selector の cwd 部分一致** — 再検討: `.` の外から target をコピペする操作が苦痛になったとき
- **done 通知の短時間抑制**(30 秒未満の working は通知しない等のチューニング) — 再検討: 鳴りすぎの実感が出たとき。値は実感から決める(実測ゼロでの事前チューニングはしない)

なお resume(M3)・遅延通知・前面抑制・`focus -` にも簡素化の提案があったが、前三者は原設計の意図的な機能、
`focus -` は実装が十分小さい(ファイル 1 つ)ため v1 に残した。

## 9. 定数表

| 定数                         | 値                   | 変更手段                 |
| ---------------------------- | -------------------- | ------------------------ |
| 状態ディレクトリ             | `~/.local/state/shiibar/` | `SHIIBAR_STATE_DIR` |
| ログレベル                   | info                 | `SHIIBAR_LOG`            |
| hooks 送信タイムアウト       | 1 秒                 | 固定                     |
| stale 閾値                   | 24h                  | 固定                     |
| stale スイープ周期           | 60 秒 + 起動時       | 固定                     |
| sessions.jsonl compaction    | 1000 行超で書き直し  | 固定                     |
| アプリ再接続バックオフ       | 1 秒 → 倍々 → 上限 30 秒 | 固定                 |
| 遅延通知                     | 3 秒(発火時に再確認) | 固定                     |
| task(prompt)の切り詰め      | 先頭 80 文字         | 固定                     |
| wait の既定タイムアウト      | なし(無限待ち)       | `--timeout`              |
