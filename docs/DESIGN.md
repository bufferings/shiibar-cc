# shiibar-cc 設計書

> menu bar agent status & jump for Claude Code + iTerm2

## 1. 目的

Claude Code のエージェント状態(working / waiting / idle と、未確認フラグ。§3)を macOS メニューバーで
常時可視化し、通知やドロップダウンのクリックひとつで該当する iTerm2 のタブへジャンプできるようにする。
併せて、状態変化をスクリプトから利用するための CLI(`wait` 等)を提供する。

### 設計原則

1. **特化する**: Claude Code 専用・iTerm2 専用。speculative generality は書かない
2. **意味の局所化**: 外部依存(iTerm2 の ID 形式、AppleScript)を知るコードは `shiibar-cc-client` の
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
launchd 常駐(§8.8)、PreToolUse 連携による waiting 解除の厳密化(§8.7)、
表示・通知の磨き込み(§8.10)、サプライチェーン対策(§10)。

各項目の「なぜ作らないか」と再検討の条件は **§8 決定の記録** にある。実装中に迷ったらまずそちらを読むこと。

## 2. アーキテクチャ

```
Claude Code hooks ──(Unix socket, NDJSON)──► shiibar-ccd
                                               │ 状態保持 + イベント配信
                        ┌──────────────────────┼──────────────────────┐
                        ▼                      ▼                      ▼
                  メニューバーアプリ        shiibar-cc            (将来の subscriber)
                  (SwiftUI, menu bar)   list/wait/watch/focus/…
```

- **target は不透明文字列**。中身は iTerm2 セッションの UUID(`$ITERM_SESSION_ID` の `:` 以降)だが、
  shiibar-ccd は解釈せず保持・転送するだけ。位置プレフィックス `wNtNpN` は**含めない** —
  hooks(report)と reconcile(iterm_targets)が同一セッションに**同じ target を導出できる**ことが
  突き合わせ(§3.5)の前提で、AppleScript からは wNtNpN を再現できない(§7-1)ため。
  意味を知るのは shiibar-cc-client の iterm モジュールと、target を生成する `shiibar-cc report` のみ
- 状態ディレクトリ: `~/.local/state/shiibar-cc/`(起動時に 0700 で作成)。
  環境変数 `SHIIBAR_CC_STATE_DIR` で上書き可(テスト・並列実行用)。
  中身: `shiibar-ccd.sock` / `state.json` / `shiibar-ccd.log`
- プロトコル: 行区切り JSON(NDJSON)。リクエスト/レスポンス + subscribe ストリーム

## 3. 状態モデル

状態は 2 つの独立したレイヤーで表す: **status**(そのセッションが何をしているか)と
**unreviewed**(あなたがまだ見ていないか)。

### 3.1 status(3 値)

| status    | 意味                         | 状態文字(表示) |
| --------- | ---------------------------- | ---------------- |
| `working` | 実行中(あなたの番ではない)   | `✳`(細)        |
| `waiting` | 許可・入力待ち(あなたの番)   | `!`(太)        |
| `idle`    | 待機中                       | `_`(薄)        |

表示に status の色は使わない(**赤は unreviewed 専用**)。見た目の正は menubar-design.html。

### 3.2 unreviewed フラグ

「そのセッションが**あなたの番の状態(`waiting`、または完了直後の `idle`)に入ってから、まだ focus していない**」
ことを表す。**`waiting` と `idle` にのみ乗る**(`working` はあなたの番ではないので持たない)。

| status + flag           | 意味                                                 |
| ----------------------- | ---------------------------------------------------- |
| `waiting` + unreviewed  | 新しい許可待ち、未確認 ← **最重要アラート**            |
| `waiting`(確認済)       | 許可待ちだが、既にそのペインに行った(対応中)         |
| `idle` + unreviewed     | 完了して結果を未確認                                  |
| `idle`(確認済)          | 見た/そもそも何もしていない(静か)                   |

set / clear の規則 — **hook イベントは §3.4 の表の flag 列に従う(status が同値でも適用する。表が正)**。
reconcile は status の遷移で決まる(§3.5):

- **立てる**: Notification(waiting 系。既に `waiting` でも、新しい要求が届いた事実を優先して立て直す)
  / 完了の Stop(background_tasks 空。既に `idle` でも立て直す)
  / reconcile: `waiting` へ遷移したとき、未追跡セッションを `idle`・`waiting` で新発見したとき(§3.5)
- **下ろす**: focus した(= seen)/ `working` にする hook(UserPromptSubmit、PostToolUse の waiting 解除、
  Stop・background_tasks 残)/ SessionStart(新規開始)/ reconcile: `working` へ遷移したとき
- **触らない**: reconcile が status 不変を再確認したとき(既に立っている `waiting` を再確認しても保持)。
  reconcile で `waiting` → `idle` へ遷移したときも**保持**する(まだ見ていない事実は変わらない。
  新たに立てもしない。§3.5)

「あなたの番(新しい要求・完了)が届いたら立ち、見た/動き出したら下りる」が要点: hook を取りこぼして
reconcile で `waiting` への遷移に気づいた場合も、未確認として通知される。

### 3.3 status の source(2 つ)

- **hooks(リアルタイム push・主軸)**: イベントを受けて即座に status を更新(§3.4)
- **`claude agents --json`(reconcile)**: アプリ起動時・daemon 再接続時・手動リロードで実行(§3.5)。
  Claude 自身の権威ある一覧を **status の正**として突き合わせ、daemon 不在中の取りこぼしを直す backstop。
  claude agents の status(4 値)は shiibar の status に `busy` / `shell` → working、`waiting` → waiting、
  `idle` → idle と対応する

hooks が主でリアルタイム。reconcile はイベントを取りこぼした隙間を埋める。両者は普段一致し、
食い違うのは daemon が誤っているとき(取りこぼし / §8.7 の誤解除)だけなので、その場合は常に claude agents を正とする。

### 3.4 hook イベント → status 遷移(テスト仕様)

「—」は status 変更なし(last_seen のみ更新)。「登録」列は未登録 target の新規作成。
**`$ITERM_SESSION_ID` の無いセッション(iTerm2 外)は追跡しない** — report は drop し、フォールバック target は作らない(§8.11)。

| イベント(条件)                                                                            | 未登録        | working | waiting | idle    | flag         |
| ------------------------------------------------------------------------------------------- | ------------- | ------- | ------- | ------- | ------------ |
| SessionStart(startup / clear / resume)                                                       | 登録:idle     | idle    | idle    | idle    | 下ろす       |
| SessionStart(compact)                                                                        | 無視          | —       | —       | —       | —            |
| UserPromptSubmit                                                                             | 登録:working  | working | working | working | 下ろす       |
| PostToolUse / PostToolUseFailure                                                             | 登録:working  | —       | working | —       | waiting→working 時に下ろす |
| Notification(permission_prompt / agent_needs_input / elicitation_dialog / **未知**)          | 登録:waiting  | waiting | waiting | waiting | **立てる**   |
| Notification(idle_prompt)                                                                    | 無視          | —       | —       | —       | —            |
| Notification(auth_success / elicitation_complete / elicitation_response / agent_completed)    | 無視          | —       | —       | —       | —            |
| Stop(background_tasks 残あり)                                                                | 登録:working  | working | working | working | 下ろす       |
| Stop(background_tasks 空)                                                                    | 登録:idle     | idle    | idle    | idle    | **立てる**   |
| SessionEnd                                                                                   | 無視          | 削除    | 削除    | 削除    | —            |
| seen(focus 成功時に client が送る。§4.4)                                                     | 無視          | —       | —       | —       | 下ろす       |

この表がそのままテーブル駆動テストの仕様である(status 列と flag 列は独立: seen は status を変えず flag だけ下ろす)。補足:

- **Notification 分岐**: 未知種別は waiting に倒す(見逃しより誤報を許容)。
  `idle_prompt`(放置アラート)は**無視**する — 入力待ち = idle は claude agents で確認済み(§7-2)で、
  取りこぼしても reconcile が backstop になるため、無条件に waiting へ倒す必要はない
- **PostToolUse は waiting 解除用**: 並行ツール実行・subagent による早期解除のレースは既知の制約として許容(§8.7)。
  notification_type を区別せず解除するので露出範囲は許可待ち以外の waiting にも及ぶが、誤解除しても reconcile が直す
- **欠損・未知フィールドの既定**: `notification_type` を欠く Notification は未知と同じ(waiting)。
  `source` を欠く/未知の SessionStart は startup と同じ(idle)。`background_tasks` を欠く Stop は空と同じ(idle+flag)
- **未登録 target**: 遷移を生むイベントのみ登録し、「無視」行では登録しない
- **同値セル**: `since` は status が変わったときのみ更新。**flag 列は status が同値でも適用する**(§3.2。
  Stop(空)は `idle` のままでも立て直し、SessionStart は `idle` のままでも下ろす)。
  status も flag も変わらなければ「—」と観測上同じ

### 3.5 reconcile(claude agents ベース)

gather は client 側(iterm モジュール)、適用は daemon の `reconcile` コマンド(§4.2)。client は
`claude agents --json` を実行し、各セッションについて:

1. **target を導出**: `pid → tty(`ps`)→ iTerm2 セッションの UUID`(§7-1)。
   iTerm2 に一致しなければ **skip**(iTerm2 外は追跡しない。§8.11)。
   **走査自体が失敗/不完全なとき(-1719 等。§7-1)は、その回は prune を行わない**(生存確認できないものを消さない。
   client は `complete:false` を付けて送り、daemon は prune だけを省いて add / update は行う。§4.2)
2. **status をマップ**(client 側): `busy` / `shell` → working、`waiting` → waiting、`idle` → idle。
   **未知の status 値は working とみなす**(セッションを live 一覧から落とすと prune で生きたエントリを
   消しかねない。追跡を維持し、flag は立てない)

daemon は受け取った live 一覧(target / status / cwd / session_id / waitingFor)を **claude agents を正として**適用する:

3. **突き合わせ(キー = target)**:
   - 未追跡 → **追加**。`idle` / `waiting` なら unreviewed を立てる(新発見 = あなたが未確認)
   - 既知 → status を反映(claude agents が常に勝つ。時刻での調停はしない。§3.3)。
     status が **`waiting` へ遷移したら unreviewed を立て、`working` へ遷移したら下ろす**(§3.2)。
     既知セッションが `idle` へ遷移した場合は立てない(完了は claude agents から判別できない。§8.12)が、
     `waiting` → `idle` で**既に立っている flag は保持**する(まだ見ていない事実は変わらない。§3.2)。
     status が不変なら flag は触らず、`last_seen` を更新する(生きたエントリを stale sweep で消さないため)。
     `waiting` の場合は `message` を `waitingFor`(ワイヤ上は `waiting_for`。§4.2)で更新する
   - **prune**: 走査が成功し、かつ claude agents の live 集合に無い target を削除し `agent_removed` を配信

reconcile は Claude 自身の権威ある登録簿を正とするので、「居ない = 本当に死んでいる」が信頼でき、
生きた `waiting` を誤って消すことはない(必ず一覧に載る)。`waiting` へ遷移すれば unreviewed を立てるので、
**daemon 不在中に許可待ちになったセッション(既知・未追跡どちらも)をここで拾える**。
唯一復元できないのは完了直後の unreviewed だけ(claude agents は完了を `idle` としか見せない。§8.12)。

### 3.6 エントリの属性と削除

- 属性: `target`(プライマリキー)/ `status` / `unreviewed` / `session_id` / `cwd`
  / `since`(現在の status に入った時刻)/ `last_seen` / `task`(最後の UserPromptSubmit の prompt 先頭 80 文字。
  自動 wake-up の例外は下記)
  / `message`(waiting の理由 = Notification の `message`、または claude agents の `waitingFor`)
- 上書き規則(同一 target への更新。§7-4): `session_id` / `cwd` は毎回。`task` は prompt を運ぶ report のみ。
  ただし prompt が `<task-notification>` で始まる UserPromptSubmit(Claude Code がバックグラウンドエージェントの
  完了を親セッションに伝える自動 wake-up。2026-07-05 実機で観測)は、§3.4 の遷移(status 列・flag 列とも)は
  通常どおり適用しつつ **task を上書きしない**(ユーザーの依頼文を自動メッセージで潰さない)。
  `message` は `waiting` への遷移/維持を起こす Notification、または reconcile が `waiting` を検出したとき(`waitingFor`)。
  `waiting` 以外に移ったら消す
- **時刻はすべて daemon の時計**(epoch 秒)。report の `ts` は表示用。daemon 内の時計は注入可能にする(stale テストのため)
- **削除経路**: (1) SessionEnd(hook・即時) (2) reconcile の prune(claude agents に居ない) (3) stale
  (last_seen から一律 24h。60 秒周期 + 起動時にスイープ)。いずれも `agent_removed` を配信。
  reconcile は生きた既知エントリの `last_seen` を更新するので、稼働中のセッションが stale 削除されることはない
- **手動削除**: `shiibar-cc remove <selector>`(reconcile が自動で消すので通常は不要だが残す)

## 4. コンポーネント

### 4.1 hooks(`hooks/`)

- `hooks/report.sh`: stdin の hook JSON をそのまま `shiibar-cc report <event>` に渡すだけの薄いスクリプト
  (`shiibar-cc` が PATH にない場合も黙って成功終了)
- ペイロードの抽出(`session_id` / `transcript_path` / `cwd` / `hook_event_name` / `notification_type` /
  `source` / `message` /(UserPromptSubmit 時)`prompt`(先頭 80 文字に切り詰め。`<task-notification>` で始まる
  自動 wake-up は prompt をペイロードから落とす — task を上書きしないため。§3.6)/(Stop 時)`background_tasks`)、
  target の生成、socket への書き込みはすべて `shiibar-cc report` 側(Rust)で行う。外部ツール(nc / jq)依存なし
- **target の生成規則**: `$ITERM_SESSION_ID`(形式 `wNtNpN:UUID`。§7-1)があれば、その **`:` 以降の
  UUID を target にする**(reconcile が AppleScript から導出する target と一致させるため。`wNtNpN` は含めない。§2)。
  無ければ(iTerm2 外: VS Code ターミナル等)**report を drop する**(飛べないので追跡しない。§8.11)。
  フォールバック target は作らない
- shiibar-ccd 不在時は **黙って成功終了**する(hooks が Claude Code の動作を阻害しないこと。タイムアウト 1 秒)。
  切り分けは `shiibar-cc doctor` で行う(§4.4)
- `hooks/settings-snippet.json`: `~/.claude/settings.json` に貼る hooks 設定
  (SessionStart / UserPromptSubmit / PostToolUse / PostToolUseFailure / Notification / Stop / SessionEnd
  → いずれも `report.sh <event>`)

### 4.2 shiibar-ccd(`crates/shiibar-ccd`)

Rust 製 daemon。tokio + Unix socket。

#### リクエスト種別

```jsonc
// hooks からの報告。クライアントは 1 行書いて close する。daemon はレスポンスを返さない
// (fire-and-forget。EOF を接続終了として扱う)
{"cmd":"report","event":"Notification","notification_type":"permission_prompt","message":"Bash: cargo test",
 "target":"D2DA6A1F-…","session_id":"…","cwd":"/path","transcript_path":"…","ts":1751600000}
{"cmd":"report","event":"UserPromptSubmit","prompt":"focus の AppleScript を実装して",
 "target":"…","session_id":"…","cwd":"…","transcript_path":"…","ts":1751600060}
{"cmd":"report","event":"Stop","target":"…","session_id":"…","cwd":"…","transcript_path":"…",
 "background_tasks":[{"id":"…","status":"running"}],"ts":1751600123}

// 現在の全エージェント状態
{"cmd":"list"}
// → {"ok":true,"agents":[{"target":"…","status":"waiting","unreviewed":true,"session_id":"…","cwd":"…",
//      "task":"…","message":"…","since":…,"last_seen":…}]}

// イベント購読(接続を保持し、1 行ずつ push)
{"cmd":"subscribe"}
// → 最初に {"event":"snapshot","agents":[…]} を 1 行 push(初期スナップショット)。以降:
//    {"event":"status_changed","agent":{…}}   … status / unreviewed / session_id / cwd / task / message のいずれかが変わったとき
//    {"event":"agent_removed","target":"…","reason":"session_end"}   … 削除経路を reason で示す:
//      "session_end"(hook)/ "stale" / "remove"(手動)/ "prune"(reconcile)。
//      アプリは通知の掃除で session_end を除外するのに使う(§4.5)。未知の reason は "remove" と同扱いでよい
//    (last_seen だけの更新では配信しない)

// reconcile(claude agents の live 一覧を client が gather して送る。§3.5)
// daemon が claude agents を正として add / update / prune / flag を適用する。
// complete = iTerm2 走査が完全だったか。false(または欠落)なら prune を行わない(§3.5)
{"cmd":"reconcile","complete":true,"sessions":[
  {"target":"…","session_id":"…","cwd":"…","status":"waiting","waiting_for":"permission prompt"}
]}  // → {"ok":true}

// エントリの手動削除・既読化(shiibar-cc remove / focus 成功時の seen)
{"cmd":"remove","target":"…"}   // → {"ok":true}(未登録でも ok)
{"cmd":"seen","target":"…"}     // → {"ok":true}(未登録でも ok)。unreviewed フラグを下ろす(status は変えない。§3.2)。
                                //    last_seen も更新しない(last_seen は report / reconcile 由来。§3.6)

// graceful 終了(メニューバーアプリの Quit 時に使う。state.json は変異ごとに保存済み)
{"cmd":"shutdown"}              // → {"ok":true} を返してから終了

// daemon 自己情報(doctor 用)
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
- **状態スナップショット**: 状態が実際に変化したとき(report は **last_seen のみの更新も変化に含む**。
  remove / seen / stale スイープは効果があった場合のみ。無視されたイベントでは書かない)に
  全状態を `state.json` へ atomic に上書き(tmp + rename)。起動時に読み込んで復元する(daemon 再起動で waiting の存在が消えないこと。
  復元後の stale 判定は通常規則に任せる。last_seen を含めて永続化するので、生きている working が
  再起動直後のスイープで誤削除されることはない)。reconcile / seen も状態を変えたら永続化する
  (reconcile は report と同様、last_seen のみの更新も変化に含む)
- **ログ**: stderr に 1 行 1 イベントで出力。メニューバーアプリが spawn する場合(§4.5)は、アプリが stderr を
  state dir の `shiibar-ccd.log` にリダイレクトする(上書きでよい。ログレスで切り分け不能な状態を作らない)。
  レベルは `SHIIBAR_CC_LOG`(error / info / debug、既定 info)。report 受信は debug、状態遷移と削除は info で記録する
- **ライフサイクル**: daemon はメニューバーアプリが起動・停止を管理する(launchd には常駐させない。§8.8)。
  開発時および M4 以前のドッグフーディングは `shiibar-ccd --foreground` で手動起動する。
  daemon 不在中の report は失われる(許容。§8.8)

### 4.3 shiibar-cc-proto / shiibar-cc-client(`crates/shiibar-cc-proto`, `crates/shiibar-cc-client`)

- `shiibar-cc-proto`: メッセージ型(serde)と NDJSON codec。daemon / ctl で共有
  (メニューバーアプリは Swift なので共有しない。プロトコル = NDJSON 自体を安定境界とする)
- `shiibar-cc-client`: socket 接続、list / subscribe / wait のクライアント実装と、**iterm モジュール**
  - `wait` は subscribe 1 本で実装する(最初に snapshot が来るので、別途 list を叩く必要はない)
  - iterm モジュール(iTerm2 の知識はここにのみ存在させる)。
    **テスト分離**: AppleScript ソースの生成と osascript 出力のパースは純関数として切り出し、
    osascript プロセス実行部だけを差し替え可能にする
    - `focus(target)`: target(UUID。`wNtNpN:UUID` 形式が渡された場合は `:` 以降を取る。§2)を使い、
      AppleScript で iTerm2 の windows→tabs→sessions を走査して一致セッションの session(pane)・tab・window を
      select、`activate`。一致なしは「該当なし」。
      **iTerm2 が起動していなければ起動せずに「該当なし」を返す**(走査は `application "iTerm2" is running` ガード内)。
      走査は明示 index + `try`(分割ペインで `index of tab` / plural 反復が `-1719/-1728` になる実機バグ回避。§7-1)
    - `focused()`: iTerm2 が最前面アプリのとき、前面 session の UUID(= target。§2)を返す。前面でなければ「なし」
    - `iterm_targets(pids)`: **reconcile 用**。渡された pid(`claude agents --json` 由来)を `ps` で tty に引き、
      iTerm2 の各セッションの tty と突き合わせて `{pid → target(UUID)}` を返す(§3.5 / §7-1)。
      iTerm2 に無い pid は返さない(iTerm2 外 = 追跡外)
    - osascript の TCC(オートメーション)権限エラーは「該当なし」と区別して呼び出し元に返す

### 4.4 shiibar-cc(`crates/shiibar-cc`)

```
shiibar-cc report <event>     # hooks 専用: stdin の hook JSON を整形して daemon に送信(M1 で前倒し実装)
shiibar-cc list [--json]      # 非 --json は「状態 / ラベル / 経過時間 / target」の整列テキスト
shiibar-cc wait <selector> --status waiting|idle|working [--timeout SEC]
shiibar-cc watch              # subscribe のイベントを行 JSON で標準出力へ
shiibar-cc focus <selector>   # ジャンプ。成功時: daemon に seen を送る
shiibar-cc focused            # 前面 iTerm2 セッションの target を出力(なければ exit 2)
shiibar-cc reconcile          # claude agents + iterm_targets を gather → daemon に reconcile を送る(§3.5)。アプリが起動時/定期/リロードで呼ぶ
shiibar-cc remove <selector>  # 幽霊エントリの手動削除(通常は reconcile が自動で消す)
shiibar-cc doctor             # 診断(下記)
```

- **selector**: target の完全一致、または `.`(カレントディレクトリと cwd が一致するエージェント。
  UUID の手打ちを不要にする)。cwd 部分一致などの拡張は実運用のシグナル待ち(§8.10)。
  複数一致は exit 1(該当なしの 2 と区別。理由は stderr)
- **focus の selector 解決**: 完全一致 target は destination そのものなので daemon を介さず iterm へ直接渡す
  (daemon が落ちていても・entry が stale で消えていてもタブが生きていれば飛べる。「該当なし」は iTerm2 走査の失敗=exit 2)。
  daemon の list を引くのは `.`(cwd 一致)を解決するときだけ。focus 成功後の `seen` 送信は
  best-effort(失敗しても飛べた事実は覆さない)
- **exit code(全サブコマンド共通)**: 0 成功 / 1 接続・内部エラー(daemon 不在含む。stderr に理由) /
  2 該当なし(wait では対象消滅。理由は stderr に出す) /
  3 osascript 権限(TCC)エラー / 124 wait タイムアウト。
  **例外は `report` のみ**: hooks を阻害しないため、daemon 不在・タイムアウトを含め常に exit 0(§4.1)
- **wait の selector 解決**: 開始時に 1 回解決し、以降はその target を追う(未登録なら出現を待つ)。
  `--timeout` 省略時は無限に待つ
- **doctor**: 以下を順に検査して人間向けに報告する —
  socket 疎通(`info` の応答)/ daemon の version・last_report_at / hooks 設定の有無
  (`~/.claude/settings.json` に report.sh が含まれるか)/ `shiibar-cc` が PATH にあるか /
  osascript の TCC 権限(無害な iTerm2 走査を 1 回試す)。「通知が来ない」の切り分けはまずこれを実行する

### 4.5 メニューバーアプリ(`app/`)

SwiftUI(macOS 13+、`MenuBarExtra` の **window スタイル**。ドロップダウンはカスタムビュー)。
トレイはロールアップ 1 アイコン常時表示、ドロップダウンが一覧、通知クリックで focus。

- **見た目の正は `docs/menubar-design.html`**(2026-07-05 確定)。トレイ = 角丸の窓 + `❯` + 状態文字の
  **テンプレートアイコン**(waiting `!` > working `✳` > idle `_` のロールアップ。unreviewed が 1 台でもいれば右肩に赤ドット)。
  描画は NSImage 合成(または attributed string)で状態変化ごとに描き直す。本節は挙動のみを規定する
- **daemon 接続**: `NWConnection` で UDS に接続し、subscribe の行 JSON を `JSONDecoder` で読む。
  切断時(daemon 再起動・スリープ復帰)は 1 秒から倍々・上限 30 秒のバックオフで再接続(snapshot で状態回復)。
  未知の event / status は無視する(前方互換)
- **ドロップダウン**: グループ見出し **Waiting / Working / Idle**(トレイと同形の窓アイコン付き。空グループは非表示)
  の下に、グループごとのカードで行を並べる。行は 2 行 — **1 行目 = 作業内容**(waiting は `message`(許可内容 /
  `waitingFor`)、それ以外は `task`(最後の依頼文)。どちらも無ければラベルを昇格。§3.6)、**2 行目 = ラベル + 経過時間**
  (開いた時点の値で固定。毎秒の更新はしない — 開き直せば最新値になる)。
  未読は 1 行目太字 + 赤ドット。並び順は waiting → working → idle、unreviewed のものを各グループ内で上に
  (開くたびに並びが安定)。クリックで `shiibar-cc focus <target>` を subprocess 実行し、**ドロップダウンを閉じる**。
  `agent_removed` で行を消す。
  「再スキャン」(Rescan = `shiibar-cc reconcile`。手動リロード)・
  ログイン時起動(Start at Login、チェック表示)・音のミュート(Mute Sound)・**Quit** は
  最上部の **⌄ メニュー**に置く。UI 文言は英語。
  Filter 欄は post-v1(v1 の topbar は ⌄ のみ。§8.10 の精神)
- **表示ラベル**: cwd をホーム配下なら `~` 起点にし、末尾 2 要素を表示(足りなければあるだけ)。
  ラベルの重複はそのまま表示する(並び順が安定していれば足りる。区別の工夫は §8.10)。
  git/worktree の概念は持たない(文字列整形のみ。`repo/branch` に見えるのは worktree のディレクトリ名の偶然)
- **デスクトップ通知**: `UNUserNotificationCenter`。**unreviewed フラグの立ち上がり**(false→true)で発火。
  クリックは delegate で受けて focus。「あなたの番になった」瞬間が通知の起点なので、状態レイヤーと一致する
  - 発火は unreviewed の立ち上がりごとに 1 回(再接続 snapshot / reconcile 経由で気づいた unreviewed も含む。切断中の遷移を取りこぼさない)。同じ立ち上がりを二重に通知しないよう発火済みを記録する
  - **トースト / 音(v1 デフォルト)**: `waiting` の立ち上がり = トースト + 音、interruption level は **time-sensitive**
    (Focus / おやすみモードでも出す。エージェントが止まって待っているのは実際 time-sensitive)。
    完了(idle+unreviewed)の立ち上がり = トースト、**音なし**(完了は頻繁に起きうるので音は付けない)。
    同一 target で `threadIdentifier` グループ化(同じエージェントの通知が積み上がらない)。
    メニューに**音のミュート切り替え**(UserDefaults 永続。ミュート中は音だけ止め、トーストは出す)。
    2 レベル別の通知/音の種類/オンオフを細かく制御する設定画面は post-v1(§8.14)
  - 遅延通知: 3 秒後にタイマー発火した時点で**最新状態を再確認**し、まだ unreviewed かつ対象が前面でなければ通知(前面抑制はこの発火時点で判定する。`shiibar-cc focused` を叩く)。スリープ跨ぎでも安全
  - 通知の掃除: focus・unreviewed が下りたときに該当 target の配信済み通知を `removeDeliveredNotifications` で消す。
    **`agent_removed` の `reason` が `session_end`(ペイン閉じ)のときは消さない**(まだ見ていない完了通知を、
    タブを閉じただけで撤去しないため。それ以外の reason は掃除してよい。§4.2)
- **異常の可視化**(黙って機能停止しない): 以下はドロップダウン**末尾**に警告行を常設表示する
  (切断はトレイ全体のグレー化が一次シグナルなので、ドロップダウン内は一覧を優先し警告を下に置く) —
  daemon と切断中(再接続バックオフ中。古いスナップショットを正常と誤認させない。
  **切断中はトレイ全体もグレー化**する)/ 通知権限が denied /
  **focus・reconcile・focused のいずれかが TCC エラー(exit 3)を返した**(reconcile が権限で沈黙すると
  backstop ごと失われるため、focus に限定しない)。
  また、アプリが実行する subprocess の失敗(非ゼロ exit)は exit code と stderr を os_log に記録する
  (黙って握りつぶさない — 本項の大原則)
- **daemon のライフサイクル管理**: アプリ起動時に socket へ接続し、応答があれば**既存 daemon にアタッチ**する
  (アプリのクラッシュ等で残った orphan daemon もここで回収される。daemon 側の二重起動防止は §4.2 の
  起動シーケンスが担う)。応答がなければ同梱の `shiibar-ccd` を spawn し、バックオフ再接続で繋ぐ。
  アプリ終了(Quit)時は `shutdown` を送って daemon も止める
- **ログイン時起動**: `SMAppService.mainApp` を使う。**初回起動時のみ自動登録**する
  (実施済みかだけを UserDefaults に記録し、以後は自動登録しない — OFF にした選択を次回起動で
  上書きしないため)。以降の ON/OFF は ⌄ メニューの「Start at Login」トグルで行い、
  チェック表示は毎回 SMAppService の status を読む(システム設定側で変えられてもずれない。
  自前フラグを状態の正にしない)。install スクリプトはアプリを一度起動するだけで、
  Login Items API を直接は呼ばない
- **reconcile の実行**: アプリは `shiibar-cc reconcile` を **(1) 起動時 / daemon 再接続時、(2) ドロップダウン
  ⌄ メニューの「再スキャン(Rescan)」** で呼ぶ(§3.5)。これで daemon 不在中の取りこぼし(幽霊・見逃した waiting)を
  status レベルで自己修復する。定期ポーリングは v1 では行わない(§8.10 — 主要な穴は起動時 reconcile で塞がり、
  osascript 走査を回し続けるコストを避ける)。hooks 主軸のリアルタイム性は保ったまま backstop になる。
  **手動 Rescan にはフィードバックを出す**: 実行中は「Rescanning…」、正常終了後は「✓ Rescan done」を
  一定時間(§9)表示して消す。件数は出さない。TCC エラー(exit 3)は警告行(下記)のまま、
  それ以外の失敗は同じ場所に「Rescan failed」を一時表示する。見た目は menubar-design.html
- 配布はしない(当面自分専用)。通知には bundle identifier 付きの .app が必要なため、
  Swift Package(executable)+ .app 化 & ad-hoc 署名のビルドスクリプトでローカルインストールする。
  ad-hoc 署名は再ビルドで通知権限がリセットされ得るため、install スクリプトで安定した署名 ID を使う
- **命名**: .app のファイル名は `ShiibarCC.app`、表示名(CFBundleName / CFBundleDisplayName —
  通知バナーやシステム設定の一覧に出る名前)は `Shiibar CC`。bundle identifier は `cc.shiibar.menubar`
  (通知・Automation の許可はこの ID に紐づく)。Swift Package 内部の
  モジュール・型のプレフィックスは `ShiibarCc`(CLI・バイナリ名は `shiibar-cc` 系)
- **同梱**: `shiibar-ccd` / `shiibar-cc` は .app の `Contents/Helpers/` に同梱する。アプリは同梱バイナリを
  絶対パスで呼ぶ(PATH 非依存)。install スクリプトが `~/.local/bin/shiibar-cc` → 同梱バイナリへの
  シンボリックリンクを張り、hooks や手動 CLI は PATH 経由で同じ実体を使う(**アプリを入れれば全部入る**)

## 5. リポジトリ構成(monorepo)

全マイルストーン完了時点の構成。`(未作成)` の項目はまだリポジトリに存在しない(ライセンスと README は本節末尾)。

```
shiibar/
├── Cargo.toml              # workspace
├── crates/
│   ├── shiibar-cc-proto/
│   ├── shiibar-cc-client/
│   ├── shiibar-ccd/
│   └── shiibar-cc/
├── app/                    # SwiftUI メニューバーアプリ(Swift Package。install.sh が .app 化)
├── hooks/
│   ├── report.sh
│   └── settings-snippet.json
├── scripts/
│   ├── install.sh          # M2: バイナリ配置 + hooks 案内 / M4 で .app 化(shiibar-ccd・shiibar-cc 同梱)+ CLI symlink + Login Items
│   ├── uninstall.sh
│   └── dev-reload.sh       # 開発中の daemon / app 差し替え(ドッグフーディング用)
├── fixtures/               # 実 hook JSON の採取物(M1 で採取・コミット。統合テストが再生する)
├── docs/
│   ├── DESIGN.md           # 本書(挙動の正)
│   ├── menubar-design.html # メニューバー確定デザイン(見た目の正)
│   ├── DEVELOPMENT.md      # 開発メモ(手順・運用。実装の進行に合わせて追記)
│   └── tasks/              # マイルストーンごとの実装指示書(M1.md, …)
├── CLAUDE.md
├── LICENSE-MIT / LICENSE-APACHE   # (未作成)
└── README.md                      # (未作成)
```

ライセンス: MIT OR Apache-2.0(デュアル)。ライセンスファイルと README は公開前に追加する。

## 6. マイルストーン

各 M の完了条件は「自動テスト」と「実機スモーク(手動)」に分ける。

| M   | 内容                                               | 自動テスト                                                   | 実機スモーク                                   |
| --- | -------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------- |
| M1  | proto + shiibar-ccd(report/list/subscribe/remove/seen/info/shutdown、state.json 復元、ログ。sessions は §8.15 で削除)+ `shiibar-cc report` + hooks | 遷移表(§3.4)のテーブル駆動テスト。fixtures 再生 → subscribe 出力列が期待と一致。daemon 再起動で状態復元 | 実セッションの遷移を watch で観測。実 hook JSON を fixtures/ に採取 |
| M2  | shiibar-cc-client + shiibar-cc(list/watch/wait/focus/focused/reconcile/remove/doctor)+ install.sh(バイナリ + hooks。daemon は手動起動、.app は M4) | exit code 系統(wait: 0/1/2/124、focus: 0/1/2/3)。selector 解決。iterm モジュールの純関数部。reconcile の add/update/prune/flag | `wait . --status idle && say done` が動く。focus で該当タブが前面に来る。reconcile で幽霊が消え・見逃した waiting が復元。doctor が全項目 green |
| M3  | (削除)resume は実装後に不要と判明し機能ごと削除した(§8.15) | —                                                            | —                                              |
| M4  | メニューバーアプリ                                 | (UI は手動中心)                                              | アプリ起動で daemon 起動・既存 daemon へのアタッチ・Quit で daemon 停止・起動時/再接続時/手動 reconcile。ロールアップ表示・ドロップダウン focus・「再スキャン」。unreviewed 通知(遅延・前面抑制: waiting 中に該当タブへフォーカスして通知が出ないこと)。focus で配信済み通知が消えること。切断中・権限 denied の警告行 |

M2 完了時点で日常投入を開始し、以降はドッグフーディングしながら M3/M4 を進める。

## 7. リスク・要検証事項(実装前に潰す)

1. **iTerm2 / AppleScript の実挙動** — ✅ 実機で検証済み(2026-07-04、M2 スモークで発見)。
   - `$ITERM_SESSION_ID` は `wNtNpN:UUID`、AppleScript の `id of session` は裸の UUID で UUID 部が一致
   - **`index of tab` は取れない**(`-1728`)。`index of window` と `id of session` は取れる → focused は UUID のみ返す
   - focus は **session(pane)も select** しないと分割ペインで違うペインに着地する(`tell s to select` 必須)
   - 分割タブの走査で `repeat with s in sessions of t`(plural)が **間欠的に `-1719`** → 明示 index + `try` で回避
   - **pid → tty(`ps`)→ iTerm2 の session tty 突き合わせ → UUID** で target を導出できる(reconcile の基盤。§3.5)
2. **claude agents / セッション状態の取得** — ✅ 実機で検証済み(2026-07-04):
   - `claude agents --json` が実在。`sessionId` / `cwd` / `pid` / `status` / `statusUpdatedAt` を返す
     (`~/.claude/sessions/<pid>.json` も同内容)
   - **session status は 4 値**: `busy` / `shell` / `idle` / `waiting`。実測: 処理中 = `busy`、入力待ち = `idle`、
     許可プロンプト表示中 = `waiting`(さらに `waitingFor: "permission prompt"` が付く)。→ **waiting(あなたの番)が取れる**
   - reconcile の status マップ: busy/shell → working、waiting → waiting、idle → idle(§3.5)
   - **完了直後は取れない**(claude agents では通常の idle と同じに見える)= reconcile で復元できない唯一の状態(§8.12)
   - **claude agents の status は実 UI とズレることがある**(2026-07-05 観測: 画面上ダイアログが見えない状態で
     `waiting` + `waitingFor:"dialog open"` を返した事例)。shiibar は §3.3 のとおり claude agents を正とするため、
     このズレは表示にそのまま映る(shiibar 側では区別できない)
3. **hook イベントのペイロード仕様** — ✅ 公式ドキュメント確認済み(2026-07-04)。Notification は `notification_type` で 8 種、
   Stop の `background_tasks`(v2.1.145+)、SessionStart の `source`、SessionEnd の `reason`。
   実機確認済み: **SessionEnd はペイン閉じで発火**(agent_removed を実測)、幽霊が残るのは daemon 不在中に閉じた場合のみ。
   **`waiting` は実「許可プロンプト」でも出る**(2026-07-04 実機スモークで確認: daemon 不在中に
   許可待ちになった実セッションを reconcile が waiting + unreviewed で復元。SessionEnd 取りこぼしの
   幽霊 prune も実機確認)。
   実機確認済み(2026-07-05、実ペイロードは fixtures/ に採取):
   **許可プロンプトの Esc 拒否では hook が一切発火しない**(PostToolUseFailure もその後の Stop も来ない —
   waiting が残り、reconcile が backstop する実例)。
   **`PostToolUseFailure` は実発火する**(Read の対象不在・Bash の非ゼロ exit で採取。`tool_response` は無く、
   失敗内容は `error` 文字列 + `is_interrupt` / `duration_ms`)。「許可 → waiting → 実行失敗 →
   working(フラグ下ろし)」の遷移列も §3.4 どおり実観測。
   **`/clear` は SessionEnd(reason:"clear") + SessionStart(source:"clear") の連続発火**で session_id が変わる。
   `/compact` は同一 session_id の SessionStart(source:"compact")。タブ閉じの SessionEnd は reason:"other"、
   対話セッションを `/exit`(または Ctrl-D)で終えると reason:"prompt_input_exit"。
   **AskUserQuestion のダイアログは Notification を即時には発火しない**(表示直後の status は working のまま =
   即答すれば「あなたの番」を取りこぼす。backstop は reconcile)。ただし elicitation ダイアログが遅延通知で
   waiting になる(下記)ことから、放置時間を延ばせば AskUserQuestion も遅延通知を出す可能性があり、
   長めに放置した再確認が要る。
   **MCP の elicitation ダイアログは `elicitation_dialog`(message: "Claude Code needs your input")を発火し、
   §3.4 どおり waiting になる**。発火は遅延する: フォームを一定時間放置すると出る。即答した場合は発火せず、
   回答後の `elicitation_response` だけが出る。`elicitation_response` は accept でも cancel でも回答/却下の
   直後に発火し、message に action("accept" / "cancel")を含む = §3.4 の無視側で正しい。`elicitation_complete`
   は未観測(elicitation_dialog → elicitation_response の 2 本のみ観測)。ツールが未承認ならまず
   `permission_prompt`("Claude needs your permission")が即時発火して waiting になる(承認済みなら出ない)。
   **別プロセスで起動されるエージェントセッション(コーディネータが spawn する類)は `$ITERM_SESSION_ID` を
   継承して hook を発火する** — 親と同じ target・自分の session_id で報告される。ただし会話ファイル
   (`~/.claude/projects/<slug>/<session_id>.jsonl`)を持たない(削除済みの resume で候補絞りの根拠に
   していた — §8.15)。**会話内の Task サブエージェントは hook を発火しない**(親の遷移列が乱れないことを
   subscribe ストリームで実観測)。
   **spawn 型セッションの表示影響(実測)**: 子の SessionStart / UserPromptSubmit / Stop / SessionEnd が
   親と同じ target を上書きする。子の Stop で親の target が idle + unreviewed になり(親が作業中でも
   「あなたの番」フラグが立つ偽アラート)、子の SessionEnd(reason:"other")で `agent_removed` =
   タブのエントリが一旦メニューバーから消える。親の次の hook で working として再登録される(task 欄は
   次の UserPromptSubmit まで空)。短命な子ならチラつく程度だが、親が idle / waiting で止まっている間に
   子が終了するとタブのエントリが消えたまま残り得る(復元の契機は起動時 / 再接続時 / 手動再スキャンのみ)。
4. **同一 iTerm2 タブ内での Claude Code 再起動**: target は同一で session_id が変わる。
   target をプライマリキーにし、session_id は属性として上書きする(§3.6)

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
- 代わりに「意味の局所化」で移行コストを抑える: target を解釈するのは iterm モジュールのみ、hook イベント名を知るのは report の正規化のみ。状態語彙(working/waiting/idle + unreviewed。§3)だけはエージェント非依存に定義し、subscriber には hook / claude agents の語彙を漏らさない(§8.13)
- **再検討の条件**: 2 つ目のエージェント/ターミナルに実際に対応する PR を書くとき。そのときに初めて、実物 2 例から共通部分を抽出する

### 8.3 サイドバー(TUI / Toolbelt)を作らない

- TUI サイドバーは既存プラグイン(hiroppy/tmux-agent-sidebar 等)の領分で、tmux を落とした今は前提も消えた
- iTerm2 Toolbelt は Python API ランタイム常駐と API 追従の保守コストに対し、得られる差分が「クリックなしの詳細一覧」のみ。メニューバー title のロールアップ常時表示で価値の大半を代替する
- **再検討の条件**: 「ドロップダウンを開いて眺めるだけで閉じる」を 1 日に何度も繰り返している自覚が出たとき。その場合も `shiibar-cc watch` の行 JSON を加工する形で軽く作れる

### 8.4 メニューバーに focus 以外の動詞を置かない

- worktree 削除等の破壊的・対話的操作は確認フローが必要で、メニューバーの 1 クリックに向かない。動線上も「結果をターミナルで確認した後」に片付けるため、CLI が自然な置き場所(幽霊エントリの `remove` も CLI に置いた)
- 例外は「再スキャン」(= reconcile。現実に合わせて表示を直すリフレッシュ/自己修復)と音のミュート切り替え(UX 設定であってエージェントへの動詞ではない。§8.14)。いずれも確認フローの要る破壊的操作ではない
- **判断基準の一般形**: 迷ったら、破壊的・対話的なら CLI、読み取り・ジャンプ・リフレッシュ・UX 設定ならメニューバー

### 8.5 メニューバーアプリは Tauri ではなく SwiftUI

- 決め手は通知クリック: Tauri v2 では macOS で通知クリックイベントが取れるか要検証(取れない場合のフォールバック設計まで必要)だったが、native なら `UNUserNotificationCenter` の delegate で確実に取れる。リスク項目が一つ消えた
- このアプリの UI はメニューバーと通知だけで webview を描く場面がなく、macOS 専用と決めた時点で Tauri のクロスプラットフォーム性は何も買っていない。常駐アプリとしてのフットプリントも native が軽い
- 代償は Rust クレート(proto/client)を共有できないことだが、subscribe は「UDS の行 JSON を読む」だけ(`NWConnection` + `JSONDecoder`)、focus は `shiibar-cc focus` の subprocess 呼び出しで足りる。設計原則 4「表示クライアントは全部 subscriber」のとおり、プロトコルが安定境界として機能する
- **再検討の条件**: 他 OS 対応や広い配布が必要になったとき。その場合も daemon / プロトコルは無変更で、subscriber を作り直すだけ

### 8.6 hooks は `shiibar-cc report` 経由で送る(nc を使わない)

- シェルは Unix ソケットに直接書けないため外部コマンドが必要になるが、`nc -U` は BSD/GNU 系で挙動が揺れる。タイムアウト 1 秒・daemon 不在時は黙って成功、という要件は Rust 側で制御する方が確実
- `report.sh` は stdin を `shiibar-cc report <event>` に渡すだけの薄いスクリプトになり、JSON 抽出(jq)も不要。プロトコルの知識は shiibar-cc-proto に一本化される
- 代償として `shiibar-cc` のバイナリ(report サブコマンドのみ)が M1 に前倒しになるが、ソケットに 1 行書くだけなのでコストはほぼゼロ

### 8.7 waiting 解除は PostToolUse で行う(既知のレースを許容)

- 許可ダイアログ表示中に、並行実行中の別ツールや subagent の PostToolUse が届くと、ユーザーが応答する前に working へ戻る誤解除があり得る
- 厳密に潰すには PreToolUse を hook して tool_use_id を対応付ける必要があり、hooks の複雑さが一段上がる。個人用ツールとしては誤解除の頻度を見てから判断する
- なお誤解除が起きても、次の reconcile(§3.5)で claude agents が `waiting` を返せば復元されるので、恒久的な取りこぼしにはならない
- **再検討の条件**: ドッグフーディングで「waiting が勝手に消えて許可待ちを見逃した」が体感で気になったとき。対策方向は PreToolUse との対応付け

### 8.8 daemon のライフサイクルはメニューバーアプリに従属させる(launchd に常駐させない)

- アプリ起動で daemon 起動(既存がいればアタッチ)、アプリ終了で daemon も終了。「アプリを止めている間は監視も止まる」を意図的な仕様とする(唯一のユーザーが望んで止めているのだから、裏で動き続ける必要がない)
- これにより launchd plist / KeepAlive / socket activation の管理が丸ごと消え、インストールは「.app 一式(daemon・CLI 同梱)」に寄る。アプリのクラッシュで残った orphan daemon は次回起動時のアタッチで回収される
- 代償: アプリ(= daemon)不在中に発火した hook の report は失われる。state.json 復元により、失われるのは不在中の遷移のみ
- **再検討の条件**: アプリを起動せず CLI(wait / watch)だけで常用したくなったとき。そのときは launchd plist または `shiibar-ccd start`(自己デーモン化)を足す

### 8.9 daemon/CLI の定数は設定ファイルにしない(アプリの UX 設定は別)

- **daemon / CLI の挙動定数**(§9: 状態ディレクトリ、閾値、タイムアウト等)は手編集の設定ファイルにしない。
  v1 の変更手段は環境変数 2 つ(`SHIIBAR_CC_STATE_DIR` / `SHIIBAR_CC_LOG`)のみ。「既定」は実装上の定数の意味で、設定可能性を約束しない
- **アプリの UX 設定は別カテゴリ**: メニューバーアプリが Preferences(macOS 標準の UserDefaults 保存)で
  通知の音/レベル等のユーザー好みを持つのは正当(手編集の config ファイルではない)。§8.14
- **再検討の条件**: 同じ daemon 定数を 3 回以上変えたくなったとき、その定数だけ環境変数化する

### 8.10 v1 から意図的に削った磨き込み

設計時に検討したが「初週のドッグフーディングで実害が出ない」と判断して落としたもの。実害が出たら足す。

- **ラベル重複の自動解決**(階層を増やす / session_id 付与) — 再検討: 同名ラベルで別エージェントに誤ジャンプしたとき
- **stale 閾値の状態別化**(死んだ working の早期掃除) — 再検討: 死んだ working が tray の表示を恒常的に濁したとき(それまでは `remove` で手動掃除)
- **selector の cwd 部分一致** — 再検討: `.` の外から target をコピペする操作が苦痛になったとき
- **完了通知の短時間抑制**(30 秒未満で終わった idle は通知しない等のチューニング) — 再検討: 鳴りすぎの実感が出たとき。値は実感から決める(実測ゼロでの事前チューニングはしない)
- **reconcile の定期ポーリング**(hooks の取りこぼしを継続的に自己修復) — 起動時 reconcile + 手動再スキャンで主要な穴は塞がるため、v1 は定期実行しない。再検討: §8.7 の誤解除などによる status ドリフトが「手動リロードでは追いつかない」と実感したとき。correctness 上は claude agents を正とする reconcile をそのまま定期実行すれば直る(コスト = osascript 走査の連続実行のみ)

遅延通知・前面抑制は当初から意図した機能であり、v1 に残す(resume は §8.15 のとおり実装後に削除した)。
`focus -`(ジャンプ元へ戻る)とメニューの「← 戻る」は 2026-07-05 のドッグフーディングで
「呼び出す自然な瞬間がない」(飛んだ先は Claude の画面でシェルがなく、キーバインドを組まない限り使えない)と
判明して削除した。再検討の条件: 帰り道が欲しい実感が出て、キーバインド等に割り当てる気になったとき
(実装は git 履歴にある。`last_focus` の保存ごと復活させる)。

### 8.11 iTerm2 外のセッションは追跡しない(フォールバック target を作らない)

- このツールの価値は「状態を見る + そのタブに飛ぶ」。iTerm2 外(VS Code ターミナル / SSH 等)のセッションは飛べないので、リストに出てもデッドウェイトにしかならない(設計原則 1「特化する」)
- `$ITERM_SESSION_ID` が無い report は drop、reconcile は pid→tty が iTerm2 に一致しないセッションを skip する(§4.1 / §3.5)。結果 daemon が持つのは常に iTerm2 セッションだけ = 全部 focus できる。追跡しないので空 target の衝突も起きず、フォールバック target は不要
- **再検討の条件**: iTerm2 以外のターミナルに focus 対応する PR を書くとき(そのとき target 生成規則ごと見直す)

### 8.12 reconcile で復元できないのは「完了直後の未確認」だけ、受け入れる

- daemon 不在中の取りこぼしは、次の reconcile(§3.5)でほぼ全部 status レベルで復元できる(waiting すら claude agents から拾える)
- 唯一の例外が「完了直後・結果未確認」= `idle` + unreviewed。claude agents はこれを通常の `idle` と区別しないため、reconcile では未確認マークを立てられず、素の `idle` で入る
- ただし完了通知は完了時(hook の Stop)に既に飛んでいるので、reconcile を跨いで失うのは「未確認マークの残り」だけ。一過性の状態であり実害は小さい。これは「穴があっても平気な作り」の許容範囲として受け入れる
- **再検討の条件**: この「跨いだ未確認が消える」が体感で問題になったとき(まず起きない見込み)

### 8.13 status は 3 値 + unreviewed フラグ。claude agents の 4 値に揃えない

- shiibar-cc の status は **working / waiting / idle**(3 値)+ unreviewed フラグ(§3)。claude agents の busy/shell/idle/waiting(4 値)には揃えない
- 理由: shiibar の状態語彙は「ユーザーが何をすべきか(注意・行動)」で定義する。`shell` は「働いている」以上の注意差が無いので working に潰す。逆に「完了直後で結果が未確認」は idle と注意差があるので unreviewed フラグで残す。claude agents がこれを `idle` と同一視するのは Claude の関心軸(ターン中か否か)が違うだけ
- claude agents の 4 値は**翻訳して取り込む入力(source)**であって、外に見せる語彙ではない(§8.2 / 設計原則 2 の延長)。外部 enum の(バージョンで変わりうる)語彙に shiibar のコアを結合しない
- **再検討の条件**: 実運用で「working と shell を分けたい」等の具体的欲求が出たとき

### 8.14 通知の設定画面は post-v1(v1 はデフォルト + ミュートのみ)

- 通知の音/トーストは好みが割れ、使ううちに変わる。正しい置き場所は設定画面(UserDefaults)だが、
  「どのツマミが要るか」は実感で決まる(自ら掲げた「実測ゼロで事前チューニングしない」§8.10)ので、
  v1 は**良いデフォルト(§4.5)+ メニューの音ミュート切り替え1つ**で始める
- **設定画面(post-v1)で持たせたいもの**(考慮だけしておく): waiting / 完了の**2 レベル別**に、
  通知のオン/オフ・音のオン/オフ・音の種類。UserDefaults に保存し、アプリの Preferences ウィンドウで編集
- **再検討の条件**: ドッグフーディングで「実際にいじりたいツマミ」が見えたとき。そのツマミだけ設定画面に足す

### 8.15 resume は実装後に削除した

- M3 として実装・実機テストまで行ったが、実運用での需要が「**そのフォルダで `claude -r` を叩く**」で
  完結していると判明した(2026-07-05)。shiibar 側の上乗せ(プロジェクト横断の履歴・正しい cwd での
  新タブ・実行中の除外)を使う場面が実際になく、続きの作業は引き継ぎドキュメント + 新セッションで
  始める運用だった
- 機能ごと削除: CLI `resume`・会話ファイルの存在フィルタ・iterm モジュールの `open_tab`・daemon の
  sessions 層(`sessions.jsonl` 追記・重複排除・compaction・`sessions` コマンド・proto の型)。
  実装は git 履歴にある
- **再検討の条件**: 終わった会話に戻りたい実感が繰り返し出たとき。そのときは CLI ではなく
  「past sessions の別一覧(いまの状態ビューとは分けた画面)から iTerm2 タブを開く」形を、
  実際の使われ方から設計し直す

## 9. 定数表

| 定数                         | 値                   | 変更手段                 |
| ---------------------------- | -------------------- | ------------------------ |
| 状態ディレクトリ             | `~/.local/state/shiibar-cc/` | `SHIIBAR_CC_STATE_DIR` |
| ログレベル                   | info                 | `SHIIBAR_CC_LOG`            |
| hooks 送信タイムアウト       | 1 秒                 | 固定                     |
| stale 閾値                   | 24h                  | 固定                     |
| stale スイープ周期           | 60 秒 + 起動時       | 固定                     |
| アプリ再接続バックオフ       | 1 秒 → 倍々 → 上限 30 秒 | 固定                 |
| 遅延通知                     | 3 秒(発火時に再確認) | 固定                     |
| task(prompt)の切り詰め      | 先頭 80 文字         | 固定                     |
| Rescan 結果の一時表示        | 2 秒                 | 固定                     |
| wait の既定タイムアウト      | なし(無限待ち)       | `--timeout`              |

## 10. サプライチェーン対策(保留)

依存は少数の主要クレート(serde / serde_json / tokio / anyhow / tempfile)のみ。現状は
`Cargo.lock` をコミット済み。過剰にはせず、以下をシグナル待ちで段階導入する:

- **依存 cooldown(pnpm の minimum-release-age 相当)**: cargo 純正の `cargo-min-publish-age`
  (`~/.cargo/config.toml` の `[registry] global-min-publish-age` + `[resolver] incompatible-publish-age`。
  Cargo.lock 固定済みの版は対象外)の **stable 化を待つ**方針(2026-07-04 調査時点で stable 未到達・状況が流動的。
  採用時に rustup / 公式で現物を再確認すること)。急ぎで欲しくなったらサードパーティ `cargo-cooldown`
- **CI を作るとき**: `cargo build --locked` + `cargo-deny`(advisories / licenses / bans)を最初から入れる。
  cargo-vet は個人用・小規模には過剰なので採らない
