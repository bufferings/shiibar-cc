# shiibar-cc 設計書

> menu bar agent status & jump for Claude Code + iTerm2

## 1. 目的

Claude Code のエージェント状態(working / waiting / idle と、未確認フラグ。§3)を macOS メニューバーで
常時可視化し、通知や一覧(ドロップダウン / 一覧ウィンドウ)のクリックひとつで該当する
iTerm2 のタブへジャンプできるようにする。
CLI(`shiibar-cc`)は hooks とアプリをつなぐ**裏方**(report / focus / reconcile / resume / conversations / doctor)であり、
利用者向けの表面はメニューバーと通知に集約する(`wait` / `watch` などのスクリプト利用も可能だが主役ではない)。

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
  中身: `shiibar-ccd.sock` / `state.json` / `shiibar-ccd.log` / `conversations-index.db`(会話索引。
  SQLite の -wal / -shm と flock 用の `.lock` が付随する。§4.6)
- プロトコル: 行区切り JSON(NDJSON)。リクエスト/レスポンス + subscribe ストリーム

## 3. 状態モデル

状態は 2 つの独立したレイヤーで表す: **status**(そのセッションが何をしているか)と
**unreviewed**(あなたがまだ見ていないか)。

### 3.1 status(3 値)

| status    | 意味                         | 表示(トレイ / 一覧行頭)                |
| --------- | ---------------------------- | ---------------------------------------- |
| `working` | 実行中(あなたの番ではない)   | 紋章 `✻` が瞬く(グリフ循環)/ グリフ循環スピナー |
| `waiting` | 許可・入力待ち(あなたの番)   | 紋章スロットに太い `!` / 輪郭の吹き出し + `!` |
| `idle`    | 待機中                       | 静止 `✻`・全体 0.8 / 薄い `✻`(静止)    |

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
- **`claude agents --json`(reconcile)**: アプリ起動時・daemon 再接続時・定期(約 1 分。§4.5/§9)・手動リロードで実行(§3.5)。
  Claude 自身の権威ある一覧を **status の正**として突き合わせ、daemon 不在中の取りこぼしを直す backstop。
  claude agents の status(4 値)は shiibar の status に `busy` / `shell` → working、`waiting` → waiting、
  `idle` → idle と対応する

hooks が主でリアルタイム。reconcile はイベントを取りこぼした隙間を埋める。両者は普段一致し、
食い違うのは daemon が誤っているとき(取りこぼし / §8.7 の誤解除)だけなので、その場合は常に claude agents を正とする。

### 3.4 hook イベント → status 遷移(テスト仕様)

「—」は status 変更なし(last_seen のみ更新)。「登録」列は未登録 target の新規作成。
**iTerm2 のセッション(`TERM_PROGRAM` が `iTerm.app` かつ `$ITERM_SESSION_ID` あり。§4.1)だけを追跡する** —
どちらかを欠く report は drop し、フォールバック target は作らない(§8.11)。

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
  / `last_assistant_message`(完了時の最後の返答 = Stop の `last_assistant_message` 先頭 200 文字。§9)
  / `created_at`(登録時刻。不変 — Newest session 並びのキー。§4.5)
  / `last_report_at`(最後に hook report を受けた時刻。表示には使っていないが記録として保持(§8.31)。
  reconcile・stale sweep では**更新しない**(`last_seen` と違い hook 経由の動きだけを刻む。
  `<task-notification>` の自動 wake-up も hook report なので更新する — セッションが動いた事実は同じ))
- 上書き規則(同一 target への更新。§7-4): `session_id` / `cwd` は毎回。`task` は prompt を運ぶ report のみ。
  ただし prompt が `<task-notification>` で始まる UserPromptSubmit(Claude Code がバックグラウンドエージェントの
  完了を親セッションに伝える自動 wake-up。2026-07-05 実機で観測)は、§3.4 の遷移(status 列・flag 列とも)は
  通常どおり適用しつつ **task を上書きしない**(ユーザーの依頼文を自動メッセージで潰さない)。
  `message` は `waiting` への遷移/維持を起こす Notification、または reconcile が `waiting` を検出したとき(`waitingFor`)。
  `waiting` 以外に移ったら消す。
  `last_assistant_message` は Stop(background_tasks 空 = idle 遷移)のときだけ保存し、`working` へ遷移したら消す
  (`message` と同じ「今の状態の説明でなくなったら持たない」規則。§3.4 の status・flag 遷移には一切影響しない)
- **時刻はすべて daemon の時計**(epoch 秒)。report の `ts` は表示用。daemon 内の時計は注入可能にする(stale テストのため)
- **削除経路**: (1) SessionEnd(hook・即時) (2) reconcile の prune(claude agents に居ない) (3) stale
  (last_seen から一律 24h。60 秒周期 + 起動時にスイープ)。いずれも `agent_removed` を配信。
  reconcile は生きた既知エントリの `last_seen` を更新するので、稼働中のセッションが stale 削除されることはない
- **手動削除**: `shiibar-cc remove <selector>`(reconcile が自動で消すので通常は不要だが残す)

## 4. コンポーネント

### 4.1 hooks(Claude Code プラグイン、`plugin/`)

- `plugin/hooks/report.sh`: stdin の hook JSON をそのまま `shiibar-cc report <event>` に渡すだけの薄いスクリプト
  (`shiibar-cc` が PATH にない場合も黙って成功終了。プラグインだけ入れて本体未導入でも Claude Code を阻害しない)
- ペイロードの抽出(`session_id` / `transcript_path` / `cwd` / `hook_event_name` / `notification_type` /
  `source` / `message` /(UserPromptSubmit 時)`prompt`(先頭 80 文字に切り詰め。`<task-notification>` で始まる
  自動 wake-up は prompt をペイロードから落とす — task を上書きしないため。§3.6)/(Stop 時)`background_tasks` と
  `last_assistant_message`(先頭 200 文字に切り詰め。§9))、
  target の生成、socket への書き込みはすべて `shiibar-cc report` 側(Rust)で行う。外部ツール(nc / jq)依存なし
- **`last_assistant_message` は切り詰めの前に軽量なマークダウン記法を除去する**(通知バナーは生テキスト
  表示のため、記法がそのまま見える — ドッグフーディングで実観測)。除去するのは:
  バッククォート(内容は残す)/ `**`・`__` のペア(内容は残す)/ 行頭の `#` 見出しマーカー /
  `[text](url)` → `text`。**単独の `*` と `_` は触らない**(snake_case やパスへの誤爆を避ける。
  取り切れない記法が残るのは許容 — 誤って壊すより残す方を選ぶ)
- **target の生成規則**: `TERM_PROGRAM` が `iTerm.app` で、**かつ** `$ITERM_SESSION_ID`(形式 `wNtNpN:UUID`。
  §7-1)があれば、その **`:` 以降の UUID を target にする**(reconcile が AppleScript から導出する target と
  一致させるため。`wNtNpN` は含めない。§2)。どちらかを欠けば(iTerm2 外: VS Code ターミナル等)
  **report を drop する**(飛べないので追跡しない。§8.11)。`ITERM_SESSION_ID` の有無だけでは判定しない —
  iTerm2 から起動した VS Code 等に相続されて残り、起動元タブの UUID を誤って指すため(§7-1)。
  フォールバック target は作らない
- shiibar-ccd 不在時は **黙って成功終了**する(hooks が Claude Code の動作を阻害しないこと。タイムアウト 1 秒)。
  切り分けは `shiibar-cc doctor` で行う(§4.4)
- **配布は Claude Code のプラグイン機構**で行う(§8.19)。リポジトリ自体がマーケットプレイスを兼ねる:
  - `.claude-plugin/marketplace.json`(リポジトリルート): マーケットプレイス名 `shiibar-cc`。
    プラグイン `shiibar-cc`(source `./plugin`)を列挙する
  - `plugin/.claude-plugin/plugin.json`: プラグインマニフェスト(name / description / version)。
    **version はリリース済みの番号を保ち、リリースコミットでタグと同じ番号に上げる**
    (`check-version.sh` がタグとの一致を検査する。§4.5 のバージョン運用)。Claude Code は
    version が変わらない限りキャッシュした plugin を使い続けるため、**利用者への配布はこの
    bump がゲート**になる — hooks を変えても bump するまで誰にも届かない
  - `plugin/hooks/hooks.json`: SessionStart / UserPromptSubmit / PostToolUse / PostToolUseFailure /
    Notification / Stop / SessionEnd の 7 イベントをいずれも
    `"${CLAUDE_PLUGIN_ROOT}"/hooks/report.sh <event>` に配線する
  - 導入は `claude plugin marketplace add bufferings/shiibar-cc` →
    `claude plugin install shiibar-cc@shiibar-cc` の 2 コマンド(brew cask 経由なら postflight が
    同じ 2 コマンドを自動実行する — §4.5)。`~/.claude/settings.json` は手編集しない(プラグインの
    hooks はユーザー設定と自動マージされ、導入の記録は Claude Code が `enabledPlugins` に書く)。
    撤去は `claude plugin uninstall shiibar-cc`

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
 "background_tasks":[],"last_assistant_message":"Done. All 54 tests pass.","ts":1751600123}

// 現在の全エージェント状態
{"cmd":"list"}
// → {"ok":true,"agents":[{"target":"…","status":"waiting","unreviewed":true,"session_id":"…","cwd":"…",
//      "task":"…","message":"…","last_assistant_message":"…","since":…,"last_seen":…,
//      "created_at":…,"last_report_at":…}]}

// イベント購読(接続を保持し、1 行ずつ push)
{"cmd":"subscribe"}
// → 最初に {"event":"snapshot","agents":[…]} を 1 行 push(初期スナップショット)。以降:
//    {"event":"status_changed","agent":{…}}   … status / unreviewed / session_id / cwd / task / message /
//                                                last_assistant_message / last_report_at のいずれかが変わったとき
//                                                (created_at は不変。last_report_at は hook report ごとに変わるため
//                                                 配信頻度は上がるが、並びのキーには使っていないので行は動かない。§4.5/§8.31)
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
    - `open_resume_window(cwd, session_id)`: **Conversations の再開用**(§4.6)。新しい iTerm2 ウィンドウを
      開き、cwd で `claude --resume <session_id>` を実行する。focus と違い **iTerm2 が起動していなければ
      起動する**(新しいウィンドウを開く動詞なので)。cwd・session_id は AppleScript / シェルの文字列として
      正しくエスケープする。起動方式(`create window` の command 直指定か `write text` か)は実機で確定する(§7-1 の流儀)
    - osascript の TCC(オートメーション)権限エラーは「該当なし」と区別して呼び出し元に返す

### 4.4 shiibar-cc(`crates/shiibar-cc`)

```
shiibar-cc report <event>     # hooks 専用: stdin の hook JSON を整形して daemon に送信(M1 で前倒し実装)
shiibar-cc list [--json]      # 非 --json は「状態 / ラベル / 経過時間 / target」の整列テキスト
shiibar-cc wait <selector> --status waiting|idle|working [--timeout SEC]
shiibar-cc watch              # subscribe のイベントを行 JSON で標準出力へ
shiibar-cc focus <selector>   # ジャンプ。成功時: daemon に seen を送る
shiibar-cc focused            # 前面 iTerm2 セッションの target を出力(なければ exit 2)
shiibar-cc reconcile          # claude agents + iterm_targets を gather → daemon に reconcile を送る(§3.5)。アプリが起動時・再接続時・定期(§4.5)・手動 Rescan で呼ぶ
shiibar-cc remove <selector>  # 幽霊エントリの手動削除(通常は reconcile が自動で消す)
shiibar-cc seen <selector>    # unreviewed フラグを消す(daemon に seen を送る。アプリの Clear badges が target ごとに呼ぶ。§4.5)
shiibar-cc resume --cwd <dir> <session-id>  # 新しい iTerm2 ウィンドウを開き <dir> で claude --resume を実行(Conversations が呼ぶ。§4.6)
shiibar-cc conversations index [--json]           # 会話索引の更新(差分。初回は全構築。--json = 進捗の行 JSON。§4.6)
shiibar-cc conversations search [<query>] [--json] # 会話の検索(追いつき込み。クエリ無しは全件 = browse。§4.6)
shiibar-cc conversations show <session-id> [--json] # 会話全文の取得(§4.6)
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
- **resume は daemon に接続しない**(iterm モジュール直呼び。§4.3 の `open_resume_window`)。
  引数は cwd と session_id の明示指定のみ — 会話の知識(transcript)は持たない(それは
  conversations モジュール。§4.6)。**cwd は絶対パス必須で、実行前に存在を確認する**(相対パス・
  不存在は AppleScript に触る前に exit 1 — transcript はフォルダより長生きするため)。
  exit code は 0 成功 / 1 内部エラー / 3 TCC(共通系統のうち 2 と 124 は使わない)
- **conversations 系も daemon に接続しない**(データ源は transcript と `~/.claude/sessions/` の
  pid ファイル。§4.6)。exit code: `index` / `search` は 0 成功(検索 0 件も成功)/ 1 内部エラー
  (索引構築不能・有効な検索語が無いクエリを含む — 黙って 0 件を返さない)。`show` は 0 / 1 / 2
  (session-id が索引に無い)。出力は既定が人間向けテキスト、`--json` で機械可読(doctor と同じ 2 面性)
- **conversations の出力 JSON(スクリプトが依存してよい公開契約)**。命名は NDJSON プロトコルと同じ
  snake_case、時刻は epoch 秒、消費者は未知フィールドを無視する(§4.2 と同じ前方互換):
  - `search`: `{"conversations":[{"session_id","cwd","title","updated_at","live"}]}` —
    新しい順。`title` は null 許容(フォールバックは表示側の責任 — §4.6)
  - `show`: `{"session_id","cwd","title","messages":[{"seq","role"("user"|"assistant"),"text"}]}` —
    `text` は全文(切り詰めは表示側)
  - `index --json`: 行 JSON のストリーム — `{"event":"start","total":N}` /
    `{"event":"progress","done":N,"total":N}`(間引きは §9)/ `{"event":"done","indexed":N,"removed":N}` /
    `{"event":"error","message":"…"}`(exit 1 と対)。**`start` は 1 ストリームに複数回現れ得て、
    カウンタは非単調**(構築者の交代 — §4.6 の中継)。消費者は常に最新の行を描く
- **conversations の排他と進捗**(§4.6): 追いつき全体は **DB パスから導出したロックファイル
  (`<DB パス>.lock`)**への `flock` で排他する(プロセスが死ねば OS が解放 — 立ちっぱなしが起きない。
  DB パスの注入 — テスト分離 — に自動で追従する)。構築の進捗は DB の
  meta 表にコミットごとに記録し、**ロック待ちになった `index` は待っている間その進捗を読んで自分の
  ストリームとして中継する** — 呼び出し側はどの `index` を呼んでも同じ形の進捗が得られ、
  子プロセスの管理を持たなくてよい
- **doctor**: 以下を順に検査して人間向けに報告する —
  socket 疎通(`info` の応答)/ daemon の version・last_report_at / hooks プラグインの有無
  (`~/.claude/settings.json` の `enabledPlugins` に `shiibar-cc@shiibar-cc` が有効値で入っているか。§4.1)/
  `shiibar-cc` が PATH にあるか /
  osascript の TCC 権限(無害な iTerm2 走査を 1 回試す)/
  Space 切り替え設定(NSGlobalDomain の `AppleSpacesSwitchOnActivate` が明示 `0` なら warn —
  OFF だと focus がウィンドウのある Space / ディスプレイに切り替われない。§7-1。
  未設定・`1`・読み取り失敗は ok 扱い — 既定が ON のため誤警告より見逃しを選ぶ)。
  「通知が来ない」「飛べない」の切り分けはまずこれを実行する。
  **`--json`** で同じ検査結果を `{"checks":[{"id","status"("ok"|"warn"|"fail"),"summary","hint"}]}` として
  出力する(アプリの Setup Check が読む。exit code の意味は人間向けと同じ。判定ロジックは CLI 側が正。
  人間向け出力だけにある `[info]`(iTerm2 未起動で TCC 未検査)は JSON では `ok` に畳む — 失敗ではないため)

### 4.5 メニューバーアプリ(`app/`)

SwiftUI(macOS 14+(§8.34)、`MenuBarExtra` の **window スタイル**。ドロップダウンはカスタムビュー)。
トレイはロールアップ 1 アイコン常時表示、ドロップダウンが一覧、通知クリックで focus。

- **見た目の正は `docs/menubar-design.html`**。トレイ = フルハイトの角丸窓 + 左上スロットの
  **1 グリフ**、の**テンプレートアイコン**(「Claude が居る窓」)。スロットの中身がロールアップ
  そのもの: waiting = **太い `!`**(紋章と入れ替え — あなたへの要求が窓に立つ)>
  working = **紋章 `✻` が瞬く**(ドロップダウン行と同じグリフ循環スピナー。§9)>
  idle = **静止した `✻`**(素の U+273B)。
  減光 2 段階: idle 0.8 / エージェントなし・切断 0.45。unreviewed が 1 台でもいれば枠の角に赤バッジ。
  描画は NSImage 合成で状態変化ごとに描き直し、**タイマーは working 表示のときだけ**動かす
  (グリフの差し替えのみなのでテンプレート画像のまま成立する)。本節は挙動のみを規定する
- **daemon 接続**: `NWConnection` で UDS に接続し、subscribe の行 JSON を `JSONDecoder` で読む。
  切断時(daemon 再起動・スリープ復帰)は 1 秒から倍々・上限 30 秒のバックオフで再接続(snapshot で状態回復)。
  未知の event / status は無視する(前方互換)
- **ドロップダウン**: フラットな一覧 + **行頭の状態記号**が既定。行は 2 行 — **1 行目 = 作業内容**(waiting は `message`(許可内容 /
  `waitingFor`)、それ以外は `task`(最後の依頼文)。どちらも無ければラベルを昇格。§3.6)、**2 行目 = ラベル + 経過時間**
  (開いた時点の値で固定。毎秒の更新はしない — 開き直せば最新値になる)。
  行頭の状態記号: **薄い `✻`(静止)= idle / 輪郭の吹き出し + 太い `!` = waiting /
  グリフ循環スピナー = working**(Claude Code の TUI と同じ `·✢✳✶✻✽` の循環・
  コサインイージング周期 2 秒。「瞬いている Claude」と「静止している Claude」の対。
  ドロップダウンが開いている間だけ動かす。見た目・数値は menubar-design.html)。
  **未確認 = 1 行目太字 + 状態記号の右肩の赤バッジ**(トレイの「窓の右肩バッジ」と同じ文法。
  行の右端には何も置かない)。
  クリックで `shiibar-cc focus <target>` を subprocess 実行し、**ドロップダウンを閉じる**。
  `agent_removed` で行を消す。
  **一覧の高さは中身が決める**(§8.32): セッション数ぶん伸び、**ドロップダウン全体
  (topbar・警告行込み)がディスプレイの可視領域(メニューバー・Dock を除く)に
  小さな余白を残して収まる高さ**で頭打ち → 一覧部分がスクロール。上限は開いた時点の、
  ドロップダウンが実際に出ているディスプレイで計算する — メニューバー由来のメニューが
  画面いっぱいまで伸びる macOS 標準の振る舞いに合わせる。ユーザーによるリサイズは無い。
  **出る位置**: 右に幅が足りる間は、アイコンを起点にその右側へ出る。
  アイコンが画面右端に近く、その置き方では収まらないときは、**アイコンを起点に左へ倒すのでは
  なく、パネル全体を左へずらして右端をディスプレイの可視領域の右端にぴったり揃える**
  (NSMenu が画面右端で行うのと同じ寄せ方)。一覧ウィンドウは「パネルと同じ位置に出す」
  規定(下記)なので、この寄せに自動的に追従する
- **並び替え**(⌄ メニュー / アプリメニューの「Sort by」ラジオ 2 択。UserDefaults 永続
  (未知の保存値は既定へフォールバック)。ラジオの並びは既定を先頭にこの順。§8.25/§8.31):
  1. **Grouped(既定)**: グループ見出し **Waiting / Working / Idle**(太字テキストのみ。
     空グループは非表示)+ グループごとのカード。並びは waiting → working → idle、
     **グループ内は新しいセッション順**(`created_at` の降順)
  2. **Newest session**: 登録時刻(`created_at`)の新しい順のフラットな一覧
  どちらのモードもキー(`created_at`)が不変なので、並びはそれ自体で安定している —
  行が動くのは Grouped でのグループ間の移動(状態変化)だけ。
  「開いた時点で並びを固定する」類いの仕組みは持たない(§8.31)。
  unreviewed を位置では示さない(未確認は太字 + 赤バッジが示す — 見た(フラグが下りた)ことで
  行が動かないため。§8.31)
- 最上部の **⌄ メニュー**の構成(共通項目の並び順は一覧ウィンドウ表示中のアプリメニュー(下記)と
  同一。**窓の動詞の島(Agents… / Conversations…)は両メニュー共通**で、アプリメニューは
  そこに Close Window が加わる。窓の性質である Keep on Top はアプリメニューにのみある。
  §8.30/§8.33/§8.40):
  **About Shiibar CC**(標準の About パネル = `orderFrontStandardAboutPanel`。
  アイコン・名前・バージョンは bundle から自動。accessory 状態では表示時に
  `NSApp.activate` が必要 — Setup Check と同じ)/ セパレーター /
  **Settings…**(設定ウィンドウを開く。下記・§8.26)/ **Setup Check…** / セパレーター /
  **Rescan**(= `shiibar-cc reconcile`。手動リロード)/
  **Clear badges**(全セッションの unreviewed フラグを消す。未読が 1 つも無ければ disabled。
  通知センターの配信済み通知は**触らない**(§8.24 — 通知は利用者が自分で消す)。
  実装は未読 target ごとに `shiibar-cc seen <target>` を呼ぶ)/
  **Sort by**(サブメニュー)/ セパレーター /
  **Agents…**(一覧(Agents)ウィンドウを開く。下記。旧称 Open as Window — §8.40。
  **窓が存在する間は disabled**)/
  **Conversations…**(会話のウィンドウを開く。§4.6。同じく**窓が存在する間は disabled**)/
  セパレーター(窓の動詞だけの島にする — Quit と同居させない。§8.40)/ **Quit**
  **メニュー項目はすべてクリックで閉じる**(Sort のラジオも閉じる — 閉じた直後に、
  開いたままのドロップダウン一覧へ並び替え結果が映るので、続けて確認できる)。
  UI 文言は英語。Filter 欄は post-v1(v1 の topbar は ⌄ のみ。§8.10 の精神)
- **一覧ウィンドウ**(⌄ → Agents…): ドロップダウンと同じ一覧を、閉じるまで出しっぱなしに
  できるウィンドウとして開く。中身は**一覧と警告行だけ**(行の見た目・並び替えはドロップダウンと
  ビューを共有する。**⌄ は置かない** — 毎日見続ける面に低頻度の操作を常駐させない。§8.30。
  操作は下記のアプリメニューが担う):
  - **タイトルバーの無い普通のウィンドウ**: タイトルバーは非表示(SwiftUI の `hiddenTitleBar`)。
    上端に残るのは信号機ボタンの細い帯だけで、その下にドロップダウンと同じ見た目の一覧が
    続く(topbar(⌄)が無い点だけが違う)。**一覧部分に窓用の配置調整はしない**
    (信号機と重ならないのは、一覧が帯の下から始まるため)。ウィンドウの `title` は **Agents** の
    まま持つ(Mission Control 等の一覧表示と、実装のタイトルフィルタが使う —
    画面のクロームには描かれない)。
    窓としての性質は普通のウィンドウ: 既定では最前面に固定しない(下記 Keep on Top)・
    全 Space に追従しない・
    よそをクリックしても閉じない・信号機の帯を掴んでドラッグできる。
    閉じるのは赤ボタンと ⌘W。**幅は固定(ドロップダウンと同じ)・縦はリサイズできる**(§8.32):
    最小はおよそ 3 行ぶん + 帯。**高さは記憶し、次回も同じ高さで開く**(位置と違って
    毎回引き伸ばし直させない。UserDefaults 永続)。初回は一覧の自然な高さ + 帯。
    一覧は窓の高さいっぱいに広がり、収まらないぶんはスクロール。
    中身の増減で窓の高さは変えない(常駐する器の大きさは人が決める。§8.32)。
    accessory 状態から開くため表示時に `NSApp.activate` が必要(Settings / Setup Check と同じ)
  - **位置は毎回アイコン直下**: Agents… を押した時点のドロップダウンパネルと同じ位置に出す
    (実装はそのパネルの画面フレームを流用してよい)。ドラッグで動かせるが**位置は記憶しない** —
    「開いたら右上(アイコンの下)に出る」が常に成り立つ。**窓が存在する間、Agents… は
    disabled**(Clear badges と同じ「意味がないときは無効」の規約。開いている窓の前面化は
    Dock クリック / ⌘Tab が担う。位置を定位置に戻したいときは閉じて開き直す)
  - **窓が存在する間だけ、アプリは通常アプリになる**(§8.30): 窓が開くと Dock と ⌘Tab に載り、
    画面上端にアプリメニューが出る。窓を閉じると accessory(常駐)に戻り、どちらも消える。
    Dock アイコンのクリック・⌘Tab での切り替えは窓を前面に出す。
    Settings / Setup Check を単独で開いても切り替えは起きない(条件は一覧ウィンドウと
    Conversations ウィンドウ — §4.6 — のどちらかが存在すること。Keep on Top は一覧ウィンドウ専用のままで、
    一覧ウィンドウが無い間は disabled)。
    メニューの Quit は ⌄ の Quit と同じ終了処理(daemon の shutdown ack を待つ経路)を通す
  - **メニューはアプリメニューと Edit メニューの 2 個**(File / Format / View / Window / Help は
    出さない)。Edit は標準項目のみ(Undo ⌘Z / Redo ⇧⌘Z / 区切り / Cut ⌘X / Copy ⌘C /
    Paste ⌘V / Select All ⌘A) — テキスト欄(検索欄・Settings)や読みのペインで標準ショートカットを
    配達するために必要(メニュー項目が無い ⌘V 等は macOS では届かない。§8.41)。アプリメニューの構成:
    About Shiibar CC / セパレーター / Settings…(⌘,)/ Setup Check… / セパレーター /
    **セクション見出し「Agents」**(macOS 標準の小さな灰色見出し — Sort by・Keep on Top の
    所属を見せる。§8.40)+ Rescan(⌘R)/ Clear badges(未読ゼロで disabled)/
    Sort by(サブメニュー)/ **Keep on Top**(トグル。チェックマークで現在値を示す。下記)/
    セパレーター / **Agents…**・**Conversations…**(⌄ メニューの同名項目と同一)・
    Close Window(⌘W。key ウィンドウを閉じる標準動作。**閉じられる窓が無ければ disabled**)/
    セパレーター / Quit Shiibar CC(⌘Q)。
    窓の項目(Keep on Top / Close Window)を除き、各項目の挙動は ⌄ メニューの同名項目と同一
  - **Keep on Top**(アプリメニューのトグル。既定 OFF): ON の間だけウィンドウを最前面
    (floating レベル)に保つ。**変えるのはウィンドウレベルだけ** — 全 Space への追従はしない、
    フォーカスも奪わない(1 クリック目で行が効く挙動と組み合わさり、最前面の一覧を見ながら
    ターミナルで作業してそのまま飛べる)。値は UserDefaults に永続し、次に開いたときも維持。
    切り替えは表示中のウィンドウに即反映(§8.33)
  - **Rescan の一時表示**: 窓では下端のステータス行(警告行と同じ場所)に一時表示する
    (Rescanning… / ✓ Rescan done / Rescan failed — 文言と表示時間はドロップダウンと同じ。§9)。
    ドロップダウンでは従来どおり topbar の ⌄ の隣
  - **行クリックで focus してもウィンドウは閉じない**(waiting が複数のとき、窓を見ながら順に
    飛んで捌ける — ドロップダウンとの本質的な差)。アプリメニューから Settings… / Setup Check…
    を開いたときも閉じない。**ウィンドウにフォーカスが無い状態でも、行は 1 クリック目で効く**
    (クリックスルー。「見て、すぐ飛ぶ」が窓の存在理由なので、前面化のための捨てクリックを
    要求しない)
  - **表示中は生きている**: スピナーはウィンドウが見えている間動かす(ドロップダウンの
    「開いている間だけ」と同じ流儀)。経過時間の基準は、開いた時点で取り直したうえで
    **表示中は毎分取り直す**(表示が分粒度なので毎秒の更新は不要。
    ドロップダウンの「開き直せば最新」を、器が長生きするぶん自動化した形)。タイマーは
    ウィンドウが見えている間だけ動かす。並び順はどちらのモードでも自然に安定なので(上記)、
    取り直しの対象は経過時間の基準だけ。通知許可の denied 判定もウィンドウを開くたびに再評価する
  - ドロップダウンの置き換えではない(どちらも存在し、どちらからでも一覧が見られる)。
    Agents… を押すとドロップダウンは閉じる(Settings… 等と同じ「移った先に仕事を渡した」流儀)
- **Settings ウィンドウ**(⌄ → Settings…): 設定をまとめる独立ウィンドウ。Setup Check と同じく
  表示時に `NSApp.activate`。**閉じるボタンは置かない**(全項目が選んだ瞬間に反映され
  「OK で確定」が無いため。閉じるのはタイトルバーの赤ボタンと ⌘W。§8.26)。
  値はすべて UserDefaults に永続。UI 文言は英語。**見た目は SwiftUI の `Form` +
  `.formStyle(.grouped)`**(System Settings と同じグループドフォーム — トグルスイッチ・
  囲みカード・行区切りは OS が描く。素の VStack + Toggle + Divider にはしない)。構成は 3 グループ:
  - **General**: Start at Login(トグル。⌄ メニューから移動 — 挙動は従来どおり `SMAppService` 直読み書き)/
    **Appearance**(ポップアップ: System / Light / Dark。既定 System = OS に従う。
    アプリ全体の外観(`NSApp.appearance`)を選んだ瞬間に切り替え、UserDefaults 永続・起動時に再適用。
    ドロップダウン・一覧ウィンドウ・Settings・Setup Check が一括で従う。
    トレイアイコンはテンプレート画像なのでメニューバー側の外観に従い続ける。§8.30)
  - **Sounds**: Mute sound(トグル。hint: "Notifications arrive silently")/
    **Waiting sound / Done sound**(ポップアップ 2 つ。**Waiting が上** — 製品の優先順
    waiting > working > idle と同じ並び。候補は `/System/Library/Sounds` の標準サウンドを
    実行時に列挙した名前 — 拡張子抜き・ソートして表示。列挙に失敗した(または空だった)場合は
    Glass のみの 1 択にフォールバックする(落ちない)。既定は**どちらも Glass** = 従来の音のまま)
  - **Mute sound が ON の間、音種 2 つは disabled 表示**にする(効かない設定を触らせない)
  - **プレビュー再生**: ポップアップをクリックで開いて音種を選ぶと、選んだ瞬間にその音を 1 回鳴らす
    (プレビューは `NSSound` 直再生 — 利用者の操作起点なので通知経由にしない)。
    ポップアップを閉じたまま ↑↓ キーで前後の音へ切り替える操作は採らない
    (macOS はクリックではコントロールにキーボードフォーカスを移さないため、
    クリックだけでは ↑↓ が届かない。§8.26)
  - 通知の実再生は音を**通知に付属**させる(§4.5 の通知の節。Focus に従う)。音量ツマミは
    持たない(付属音に音量の概念がないため見送り。§8.26)
  - **Conversations**: **Text size**(ステッパー。Conversations ウィンドウの本文サイズ 11〜18pt・
    既定 13pt — §9。ウィンドウ上の ⌘+ / ⌘− / ⌘0 と同じ値を読み書きする — §4.6)
- **Setup Check ウィンドウ**(⌄ → Setup Check…): 導入状態の一覧点検。`shiibar-cc doctor --json`(§4.4)の
  結果に、アプリでしか取れない 2 項目(通知許可の状態 / ログイン時起動の登録状態)を加えて
  ✓/⚠/✗ で表示し、各行に対処のヒントを一言添える。Re-run ボタン付き。
  **チェックはウィンドウを開くたびに自動実行する**(閉じて開き直した場合も含む —
  前回の結果を古いまま見せない。Re-run はその上での手動再実行)。
  **見た目は Settings ウィンドウと同じ SwiftUI `Form` + `.formStyle(.grouped)`**
  (2 グループ: **Doctor** = doctor 由来のチェック / **App** = アプリ側 2 項目。
  ウィンドウ内の大見出しは置かない — タイトルバーが兼ねる。
  Re-run は Form の外の常時表示フッターに置きスクロールに巻き込まない)。
  accessory 状態では表示時に `NSApp.activate` が必要。
  判定ロジックはアプリに複製しない(doctor が正)。将来のドロップ導入時のオンボーディングを兼ねる(§8.18)
- **表示ラベル**: cwd の**末尾 2 要素のみ**を表示(足りなければあるだけ。ホーム配下は
  ホーム相対で数え、`~/` 接頭辞は付けない — ほぼ全てがホーム配下なので情報を運ばない。
  cwd がホームそのものの場合だけ `~`)。
  ラベルの重複はそのまま表示する(並び順が安定していれば足りる。区別の工夫は §8.10)。
  git/worktree の概念は持たない(文字列整形のみ。`repo/branch` に見えるのは worktree のディレクトリ名の偶然)
- **デスクトップ通知**: `UNUserNotificationCenter`。**unreviewed フラグの立ち上がり**(false→true)で発火。
  クリックは delegate で受けて focus。「あなたの番になった」瞬間が通知の起点なので、状態レイヤーと一致する
  - 発火は unreviewed の立ち上がりごとに 1 回(再接続 snapshot / reconcile 経由で気づいた unreviewed も含む。切断中の遷移を取りこぼさない)。同じ立ち上がりを二重に通知しないよう発火済みを記録する。
    ただし**アプリ起動後の最初の snapshot は基準線**とし、そこに既に立っている unreviewed には通知しない
    (起動時に過去の未読を再通知しない — 積み残しは赤バッジが示す。起動後の再接続 snapshot は発火対象のまま)
  - **トースト / 音(v1 デフォルト)**: `waiting` の立ち上がり = トースト + 音、interruption level は **time-sensitive**
    (Focus / おやすみモードでも出す。エージェントが止まって待っているのは実際 time-sensitive)。
    完了(idle+unreviewed)の立ち上がり = トースト + **音**(interruption level は active。§8.16)。
    **音は通知に付属させて鳴らす = Focus・おやすみモードに従う**(アプリが直接は鳴らさない。§8.27)。
    音の種類は waiting / 完了それぞれ Settings ウィンドウで選択(`UNNotificationSound(named:)` で
    macOS 標準サウンドを指定。既定はどちらも Glass。§8.26)。
    同一 target で `threadIdentifier` グループ化(同じエージェントの通知が積み上がらない)。
    **Mute sound**(ON = 音を止める = 通知に音を付けない。Settings ウィンドウのトグル。UserDefaults 永続)。
    バナーを止めたい場合はアプリ内スイッチではなく **macOS のシステム設定 > 通知**で行う(§8.27)。
    ミュート中も unreviewed フラグ・赤バッジ・トレイ表示は動き続ける(見張りは止まらない)。
    イベント別の通知オン/オフの細かい制御は持たない(§8.26 で見送り)
  - **通知の内容**: waiting = タイトル `Waiting for you — <ラベル>`、サブタイトルに `message`(待ちの種別。
    例 "Claude needs your permission")、本文に `task`(どの用件で待たれているか)。
    完了 = タイトル `Done — <ラベル>`、本文に `last_assistant_message`(無ければ `task`)。
    いずれも無いフィールドは行ごと省く(フックが運んでこないもの — 質問文そのもの等 — は出さない。§7-3)
  - 遅延通知: 3 秒後にタイマー発火した時点で**最新状態を再確認**し、まだ unreviewed なら通知する
    (即応した場合だけ通知を出さない仕組み。スリープ跨ぎでも安全)。**対象が前面でも出す**(§8.16 —
    前面かどうかの判定は行わず、`shiibar-cc focused` も呼ばない)
  - 通知の掃除: focus・unreviewed が下りたときに該当 target の配信済み通知を `removeDeliveredNotifications` で消す。
    **`agent_removed` の `reason` が `session_end`(ペイン閉じ)のときは消さない**(まだ見ていない完了通知を、
    タブを閉じただけで撤去しないため。それ以外の reason は掃除してよい。§4.2)
- **異常の可視化**(黙って機能停止しない): 以下は一覧(ドロップダウン / 一覧ウィンドウ)の
  **末尾**に警告行を常設表示する
  (切断はトレイ全体のグレー化が一次シグナルなので、一覧を優先し警告を下に置く) —
  daemon と切断中(再接続バックオフ中。古いスナップショットを正常と誤認させない。
  **切断中はトレイ全体もグレー化**する)/ 通知権限が denied /
  **focus・reconcile のいずれかが TCC エラー(exit 3)を返した**(reconcile が権限で沈黙すると
  backstop ごと失われるため、focus に限定しない)。
  **通知権限の denied 判定はドロップダウンを開くたびに再評価する**(起動後に許可を変えても
  アプリの再起動なしで警告行の表示/非表示に反映される)。
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
- **reconcile の実行**: アプリは `shiibar-cc reconcile` を **(1) 起動時 / daemon 再接続時、(2) 定期
  (`NSBackgroundActivityScheduler`、間隔 約 60 秒・tolerance 30 秒。§9。システムスリープ中は OS が
  スケジュールを止め、復帰後に自然に再開する — 自前の画面状態検知はしない)、(3) 手動 Rescan(ドロップダウンの
  ⌄ メニュー / 一覧ウィンドウ表示中のアプリメニュー。⌘R)** で呼ぶ(§3.5/§8.22)。これで hooks の取りこぼしによる
  status ドリフト(「working のまま固まる」等)と daemon 不在中の穴(幽霊・見逃した waiting)を自己修復する。
  定期実行はフィードバック表示を出さない(「Rescanning…」等は手動 Rescan 専用。
  osascript 走査を回し続けるコストを避ける)。hooks 主軸のリアルタイム性は保ったまま backstop になる。
  **手動 Rescan にはフィードバックを出す**: 実行中は「Rescanning…」、正常終了後は「✓ Rescan done」を
  一定時間(§9)表示して消す。件数は出さない。TCC エラー(exit 3)は警告行(下記)のまま、
  それ以外の失敗は同じ場所に「Rescan failed」を一時表示する。見た目は menubar-design.html
- **配布は brew cask(自前 tap `bufferings/homebrew-tap`。arm64 のみ)を正式経路とする**:
  `.github/workflows/release.yml` がタグ push で Developer ID 署名・公証済みの .app を zip にして
  draft Release を作り、所有者の実機スモーク後の publish で `bump-cask.yml` が tap の cask を更新する
  (`brew install --cask bufferings/tap/shiibar-cc`)。ソースビルド(開発者向け、Intel Mac 向けの代替
  としては扱わない)は Swift Package(executable)+ .app 化のビルドスクリプト(`scripts/dev-install.sh`)
  でローカルインストールする。通知には bundle identifier 付きの .app が必要で、ソースビルドはローカル署名
  する。ad-hoc 署名は再ビルドで通知権限がリセットされ得るため、install スクリプトで安定した署名 ID を使う。
  **hooks plugin の導入と更新も cask の postflight が担う**: 初回は自動インストール、upgrade 時は
  plugin が有効なら hooks を更新する(3 分岐の詳細・best-effort の性質・配達コマンドは §8.28)。
  **plugin.json の version はリリースコミットでタグと同じ番号に上げる** — bump が配布のゲート(§4.1)。
  タグ時点で tag = Cargo.toml = plugin.json の三点一致を `check-version.sh` が検査する
- **命名**: .app のファイル名は `Shiibar CC.app`、表示名(CFBundleName / CFBundleDisplayName —
  通知バナーやシステム設定の一覧に出る名前)も `Shiibar CC`。**ファイル名と表示名は必ず一致させる**
  (システム設定 > 通知 の一覧は、名前解決に失敗するとファイル名(拡張子抜き)にフォールバックする —
  §8.21)。bundle identifier は `cc.shiibar.menubar`(通知・Automation の許可はこの ID に紐づく)。
  Swift Package 内部のモジュール・型のプレフィックスは `ShiibarCc`(CLI・バイナリ名は `shiibar-cc` 系)
- **アプリアイコン**(Finder・通知バナー・⌘Tab に出る角丸タイル): 黒塗りのタイル自体を「窓」と
  読ませ、**左上 1/4 エリアの中央に大きな ✻(素の U+273B)**、**右肩に赤バッジ**(明色ハロー付き —
  「通知してくる見張り」の一言。状態記号の縦積みは持たない)。32px 以下は ✻ のみ(中央)の簡略版
  (バッジは小サイズで潰れるため付けない)。install スクリプトが生成スクリプトから `.icns` を
  作って同梱する(`CFBundleIconFile`)。ジオメトリの正は生成スクリプト(リポジトリ内)
- **同梱**: `shiibar-ccd` / `shiibar-cc` は .app の `Contents/Helpers/` に同梱する。アプリは同梱バイナリを
  絶対パスで呼ぶ(PATH 非依存)。install スクリプトが `~/.local/bin/shiibar-cc` → 同梱バイナリへの
  シンボリックリンクを張り、hooks や手動 CLI は PATH 経由で同じ実体を使う(**アプリを入れれば全部入る**)

### 4.6 Conversations(会話の一覧・検索・閲覧・再開)

会話の履歴をフォルダ横断で**眺め**(browse)、**探し**(search)、**読み**(read)、必要なら新しい
iTerm2 ウィンドウで**再開**する機能。消費者は 2 人 — **ウィンドウ(アプリ)とスクリプト(CLI)** — で、
どちらも同じ CLI コマンドを使う。いまの状態ビュー(§4.5)とは独立した読み取り専用の機能で、
**daemon・プロトコル・hooks・状態モデルには一切関与しない**(§8.34)。
会話の識別子は Claude Code の session ID をそのまま使う。見た目の正は `docs/conversations-design.html`。

#### 索引と検索(CLI・Rust)

- **不変条件**: `conversations` の各コマンドは **transcript の現在に対して答える**。DB は
  アクセス時に自己更新される内部キャッシュ(冪等・クラッシュ安全)であり、利用者が索引の状態を
  意識する必要はない(§8.34)
- **データ源**: `~/.claude/projects/<cwd スラグ>/<session_id>.jsonl`(Claude Code の transcript。§7-6)。
  **非公開フォーマットへの読み取り専用の依存**であり、Claude Code の更新で一覧・閲覧が壊れ得る
  (README に明記する)。**transcript と pid ファイルの知識、SQLite は `crates/shiibar-cc` 内の
  conversations モジュール一箇所に閉じ込める**(iTerm2 の知識を iterm モジュールに閉じるのと同じ
  局所化 — 設計原則 2)。アプリは CLI を呼んで JSON を読むだけで、Swift に transcript パースも
  SQLite も持たない(daemon に対する表示クライアントの姿 — 設計原則 4 — が索引に対しても成り立つ)
- **CLI 動詞**(契約・JSON スキーマは §4.4): `conversations index` / `conversations search` /
  `conversations show`。**外部との境界は各コマンドの出力 JSON だけ**で、DB スキーマは Rust の私有
  (自由に変更できる。NDJSON プロトコルが daemon の安定境界であるのと同じ関係)
- **索引の内容**: **全会話**(実行中も含む)+ **live/past フラグ**。絞り込みは消費者の責任。
  会話ごとに: タイトル(**最後の `custom-title` → 無ければ最後の `ai-title` → 無ければ最初の
  ユーザープロンプトの先頭 1 行・80 文字(80 文字は §9 の task と同値)→ それも無ければ null**。
  フォルダラベルへの最終フォールバックは表示側の責任。§7-6)/ cwd(アクティブ経路上の最初の非空値)/
  最終更新(transcript の mtime)/ 発話列(出現順 + 役割 + 全文)。
  発話列に入れるのは**アクティブ経路上の、人の発話と Claude のテキスト返答のみ**。
  除外: ツール実行・実行結果・システム行・スラッシュコマンド出力・`<task-notification>` の
  自動 wake-up・sidechain(§7-6)。書きかけの行(実行中の末尾)や壊れた行は skip して続行する
- **アクティブ経路**: 葉 = **ファイル内で最後に現れる、完全な・sidechain でない user / assistant 行**
  (追記専用の木では、最後に追記されたノードは必ずその時点のアクティブ枝上にある — rewind も
  新しい枝の追記なので同じ。§7-6)。そこから `parentUuid` を遡って集める。**遡行は uuid を持つ
  全行が対象**(system / attachment 行も木に参加する — §7-6。user / assistant だけで親を引くと
  途中で経路が切れる)。**収集は user / assistant のみ**。親が見つからない場合は
  そこを根として打ち切る(破損時もエラーにせず読めた範囲を使う)。`last-prompt` の `leafUuid` は
  決定には使わず、実装時の答え合わせに使う(§7-6)
- **live/past フラグ**: `~/.claude/sessions/<pid>.json`(§7-6)を読み、**`kill(pid, 0)` による生存 +
  プロセス名が `claude`**(判定は argv[0] — `p_comm` はバージョン文字列を返すため不可。§7-6)の
  2 段チェックを通ったものの session_id を live とする。pid の再利用は
  レジストリがファイル名 = pid であるため自己解決する(新しい claude が同名ファイルを上書きし、
  中身は常に現住者のもの)。`claude agents` は使わない(§8.34)
- **追いつき**(`index` と `search` の前段。冪等。`show` は追いつかない — DB を読むだけで、
  一覧に出た会話は索引済みなので常に読める): ロックファイル(`<DB パス>.lock`)への **`flock` で
  全体を排他**(§4.4)→ (1) `~/.claude/projects` を stat 掃引し、`(パス, mtime, サイズ)` が変わった
  ファイルだけ**全体を読み直してアクティブ経路を計算し直し、その会話の行を丸ごと入れ替える**
  (ファイル内の追記差分管理はしない — 全読み直しでも平均数 ms・最大 0.1 秒 <§7-6 の実測> で、
  rewind を機構なしで吸収できる)。消えたファイルは索引からも消す (2) pid ファイルから live/past
  フラグを更新する。**search はこのロックを待って必ず追いつく** — 全構築(初回・スキーマ更新後・
  破損後)に当たった場合も完了まで待つ(stderr に "Building index…" の一言)。構築中の部分結果は
  返さない
- **SQLite の規律**: WAL モード / 書き込みトランザクションは `BEGIN IMMEDIATE` / **コミットは
  会話単位**(中断・クラッシュで作業が失われず、次回は続きから)/ ロック待ち時間は明示設定 /
  全再構築は**ファイル削除ではなく同一接続内のテーブル作り直し**(並行プロセスとの削除レースを
  作らない)。スキーマ版は meta 表に持ち、不一致・破損検知(open / クエリ失敗)で自動的に全再構築。
  手動の再インデックス動詞・UI は持たない(逃げ道は DB ファイルの削除。DEVELOPMENT.md)
- **DB**: SQLite 1 ファイル `conversations-index.db` を**状態ディレクトリ**(§2。
  `SHIIBAR_CC_STATE_DIR` に従う — ディレクトリが無ければ 0700 で作る)に置く。DB ファイルは
  **0600 を明示**(transcript 本体の保護 — dir 0700 / file 0600、実測 — より緩くしない)。
  FTS5 + **trigram トークナイザ**(辞書レスで言語非依存の部分一致。§8.34)。リンク先は macOS 同梱の
  libsqlite3(FTS5 実測確認済み。§7-6。バンドルしない — §10)
- **検索**(`conversations search <query>`): 追いつき後に検索。クエリは**前後の空白(半角・全角)を
  trim** し、**空白で語に分割して AND** — すべての語が、その会話のタイトル・cwd・本文の合算の
  どこかに現れる会話がヒットする(フレーズ検索 = 空白を含む連続文字列の検索は持たない)。
  各語は大文字小文字無視の単純部分一致。**クエリと索引する本文は NFC に正規化してから照合する**
  (正準等価の同一視 — 分解形(NFD)の濁点・半濁点はバイト列が違うだけの同じ文字。§8.38(12))。
  アクセントや濁点を**取り除く**同一視はしない(§7-6)。**語は 2 文字から** —
  1 文字の語は無視し、有効な語が 1 つも無ければ exit 1(§4.4。黙って 0 件を返さない)。
  語数の上限は設けない。実行は**語ごとに独立のクエリ**で会話の集合を取り、
  **コードで積集合**する(語の長さによる経路の場合分けを作らない。クエリは直列で足りる — 実測は §7-6): **2 文字の語 = LIKE**
  (`%` `_` はエスケープ。唯一の LIKE 経路。大文字小文字の畳みは ASCII のみ — SQLite の LIKE の仕様。
  実測 10ms/3.5M 文字 — §7-6)/ **3 文字以上の語 = FTS の MATCH**(語をフレーズ文字列として引用し、
  内部の `"` は二重化 — FTS5 のクエリ言語を注入させない)。
  返すのは会話ごとに 1 件・5 フィールド(§4.4)。並びは常に新しい順。クエリ無し(trim 後空)は全件(browse)
- **全文の取得**(`conversations show <session-id>`): その会話の発話列全体を返す(切り詰めは
  表示側の責任 — DB は全文を持つ)
- **索引の更新**(`conversations index`): 追いつきだけを実行する動詞(+ `--json` で進捗ストリーム —
  §4.4)。構築の進捗は meta 表にコミットごとに記録し、**ロック待ちになった `index` は待っている間
  その進捗を読んで自分のストリームとして中継する**(呼び出し側は子プロセスの管理を持たなくてよい)。
  処理は新しい順

#### ウィンドウ(アプリ)

- **入り口**: ⌄ メニューとアプリメニューの `Conversations…`(§4.5 の「窓の動詞の島」— §8.40)。
  窓が存在する間は disabled(Agents… と同じ規約)。窓が存在する間だけ通常アプリに
  なる規則(§8.30)はこの窓にも適用する
- **ウィンドウ**: 2 ペイン(左 = 検索 + 一覧 + ステータス行、右 = 会話の全文 + Resume)。
  クロームは**フルハイトサイドバー**: タイトルバー非表示で、信号機はサイドバーの上に載り、
  サイドバーの色(サイドバー素材)がウィンドウ上端まで届く。右ペインは通常のウィンドウ背景 —
  選ぶ場所と読む場所を背景で分ける(`title` は **Conversations**。一覧ウィンドウの「信号機の帯」とは
  意図的に違う — §8.35)。縦横ともリサイズ可で、**サイズ・位置を記憶する**(一覧ウィンドウと違い
  アイコン直下の定位置規則は持たない — アイコン起点の画面ではないため)。閉じるのは赤ボタンと ⌘W
- **一覧(左)**: `conversations search` の結果を**全部**出す(実行中の会話も含む)。新しい順・
  罫線もグループ見出しも無し。行は 2 行 — **1 行目 = タイトル**(null はフォルダラベルに落とす)**+
  経過時間(右端・淡色)**/ **2 行目 = フォルダラベル**(ラベルは §4.5 と同じ末尾 2 要素規則)。
  行にはホバーのハイライト(ドロップダウンと同じ作法)。**実行中の会話は 2 行目に
  `running` の淡いテキスト印**(Agents ビューの状態記号は使わない — この印の鮮度は最後の検索
  実行時点であり、いまの状態を主張しない)。live の行でも**下部パネルは常に同じ高さで出す** — Resume ボタンを
  disabled にし、左に `This conversation is running` の一言を淡く添える(押せないではなく
  押す必要がないと読めるように。実行中の会話への動詞は実感が出たら設計する — §8.38)
- **検索欄(左上)**: インクリメンタル。デバウンス(§9)後に `conversations search --json` を
  subprocess 実行し、進行中の実行はキャンセルして新しいクエリを投げる。
  クエリは送信前に NFC へ正規化する(CLI 側でも正規化する — 二重の防御。§8.38(12))。
  **日本語入力(IME)の扱い**: 変換が未確定(marked text)の間は検索を発行せず、
  **確定した時点で必ず発行する**(ひらがなの中間状態で無駄な検索が走らない。§8.38(12))。
  **⌘F は検索欄にフォーカスを移す**(Conversations ウィンドウがキーのとき。文書内検索の
  標準ショートカットの受け皿 — 検索欄が文書内ヒットのナビゲーションも兼ねる画面なので)。**trim 後に有効な語
  (2 文字以上)が 1 つも無い間は search を発行せず** browse 一覧のまま(プレースホルダ
  `Search (2+ characters)`)。検索欄の隣に **⟳ ボタン** — 同じクエリで search を再実行する
  (よそで終わった会話を拾う手動リフレッシュ。Rescan と同じ文法)。
  **押下には必ず見える反応がある**: 実行中はボタンを disabled にし、ステータス行に
  `Refreshing…` を出し、**完了後はステータス行に `Updated · N conversations` を 2 秒**
  (Rescan の一時表示 — §9 — と同値)出してから通常表示に戻る(検索は数十 ms で終わるため、
  実行中表示だけでは知覚できない — §8.38)。
  **search がエラー終了したときは前回の結果を維持**してステータス行にエラーを出す
  (打鍵途中の一過性の失敗で一覧を消さない)
- **表示更新の契機はすべて利用者起点**: ウィンドウを開いたとき / 打鍵 / ⟳ / この画面からの
  Resume 成功直後。**勝手に変わらない**(検索していないのに結果が変わる驚きを作らない。§8.34)。
  FSEvents による監視は持たない
- **会話の表示(右)**: 行を選ぶと `conversations show` で**全文を 1 回で取得**し、古い順に表示
  (下端 = 最新)。スクロールは自由。show が exit 2(索引に無い — 直前に消えた等)なら
  プレビューをクリアしてステータス行に一言、exit 1 ならエラー表示(一覧は維持)。
  **描画の文法**(見た目の正は conversations-design.html): **自分の発言 = 全幅の帯**(`❯` +
  発言は通常ウェイト・本文 +0.5pt。セミボールドは `❯` グリフのみ。発言そのものをそのまま載せる —
  Markdown 描画はしない)/
  **Claude の発言 = Markdown を描画した本文**。役割ラベルの行は置かない(帯 = 自分、地の文 = Claude)。
  メッセージ間のツール実行は何も描かない。
  **Claude の各発言の先頭に ⏺ マーカー**(淡い二次色・本文より小さい・状態の意味なし):
  1 つの指示に発言が連続しても境目が読めるようにする印で、すべての発言に常に付ける。
  本文の左に**ぶら下げ**(折り返しは ⏺ の下に回り込まない)、帯の `❯` と同じグリフ列に揃える。
  **⏺ は描画後テキストに含めない**(ヒット計算・畳み境界の対象外 — 「⏺」で検索してもヒットしない)。
  **Markdown の描画範囲**: フェンスコードブロック(モノスペース + 背景 + 横スクロール)/
  見出し / 箇条書き・番号付きリスト / 段落 / **パイプ表**(下記)/ インラインの code・強調(太字・
  斜体)・打ち消し・リンク(スタイルのみでよい)。それ以外の構文(引用など)は素のテキストのまま
  出す — 描画に失敗したメッセージも素のテキストにフォールバックして落ちない。
  **パイプ表**: GitHub 形式(ヘッダ行 + `|---|` 区切り行 + データ行。区切り行が無いパイプ入りの行は
  表とみなさず段落のまま)をグリッドで描画する — ヘッダ強調・行間罫線・全列左揃え(列揃え指定は
  無視)・セル内のインライン有効(§8.37)。セルは幅の上限(約 28em)で折り返し、
  それでも溢れる表だけ表の中で横スクロール(§8.38)。
  **区切り行と `|` 記号は構文なので描画後テキストに含めない** — ヒット計算・畳み境界の対象は
  セルの見える文字だけ。壊れた表(列数不一致など)は読めた形で出す。
  **強調の補完**: 強調記号(`**` 等)が CJK の句読点・括弧に隣接すると標準パーサが
  解釈しないことがある(CommonMark の flanking 規則 — 日本語の会話で頻出)。
  標準パーサが素のまま残した強調記号は、**対応の取れた記号の組だけを対象にした保守的な補完**で
  強調として描画する — 入れ子・対応の曖昧な記号は補完せず素のまま
  (誤爆より取りこぼしを選ぶ。§8.38)
- **ヒットナビゲーション**: show 取得後、アプリが**描画後のテキスト**(Markdown 記号を消費した後の、
  画面に見えている文字列)から**各語の全出現**を計算し(大文字小文字無視の部分一致 —
  会話の絞り込みは CLI が生テキストで行い、文書内の位置決めは表示テキストで行う。
  記号にだけヒットした会話は一覧に出るが本文ヒット 0 件になり得る — それは正しい表示)、
  **本文に 1 件以上あるときだけ**会話の上部に検索バー行を出して全語を同色でハイライト
  (現在位置のみ濃く)、初期位置は**どれかの語の最新の出現**。0 件なら検索バー行を出さず下端から。
  **検索バー行は macOS 標準の文書内検索の文法**(§8.38): カウンタは `N of M`、移動は
  **‹ › のセグメンテッドコントロール**(ツールチップ付き)。次(`›`・⌘G)= 新しい方へ /
  前(`‹`・⇧⌘G)= 古い方へ。**端まで行ったら反対側へ折り返す**(⌘G の慣習)。
  コントロールは**内容サイズ・左寄せ**(バーの幅いっぱいに伸ばさない — §8.38)。
  **ヒットが 1 件でも、押下のたびに現在のヒットへスクロールする**
  (現在位置が変わらなくても再スクロール — 画面を離れても戻れる)。
  クエリを打ち替えたらハイライトとカウンタは再計算するが**スクロールは動かさない**。
  **ミニマップ**(§8.39): 右端の幅 20pt の列に会話全体の略図(帯 = 濃い縞・本文 = 淡い塊・
  コードブロック = 中間の塊。文字は描かない)を常時表示し、**それ自体がスクロールバーを兼ねる** —
  いま見えている範囲を半透明のグレー帯(つまみ)で示し、ドラッグでスクロール・ホバーで濃く・
  地のクリックでその位置へジャンプ。右ペイン内の OS スクロールバーは表示しない(位置表示を
  二重にしない)。検索中は**ヒットの線**(現在位置だけ濃く)をミニマップ上に重ねる —
  ヒット分布の表示はミニマップが担う。位置は実レイアウト由来。
  **本文の文字はミニマップの手前 8pt で折り返す**(帯・コードブロックの背景の伸び方は
  変えない — 文字だけが隙間を取る。§9)
- **表示の状態規則**: 一覧の更新はプレビューに触らない(一覧とプレビューは別の状態。選択は
  session_id で保持し、選択中の会話が結果から消えたときだけプレビューをクリア)。**スクロール
  位置は会話ごとに記憶**(ウィンドウを閉じたら破棄。復帰時は記憶が初期位置に勝つ)。
  **500 文字(§9。描画後テキストで数える)を超えるメッセージは畳んで `Show full message` で展開**。
  畳みの見えない部分にヒットがあるときは展開ボタンに件数バッジ(`N matches`)を付ける。
  畳まれた部分へのヒットもカウンタに数え、‹ ›(⌘G / ⇧⌘G)でジャンプしたら自動で展開する。
  **展開したメッセージの末尾には `Show less`** — 畳み直しで視点がそのメッセージから飛ばないよう
  スクロールを寄せる。展開状態は選択の切り替えで破棄
- **下端(最新)の手がかり**(§8.39): 最後のメッセージの下に、罫線ではさんだ淡い一行
  **`Latest message · <経過時間> ago`**(終端マーカー)— 開いた瞬間に「ここが末尾で、いま最新を
  見ている」が読める。**上に続きがある間だけ**ヘッダの下に薄いスクロールシャドウを出す
  (最上部まで遡ると消える)
- **文字サイズ**: ⌘+ / ⌘− / ⌘0(リセット)で右ペインの本文サイズを
  11〜18pt(既定 13pt — §9)で調整。コードブロックは本文 −1.5pt で連動。一覧・ステータス行は固定。
  値は UserDefaults に永続し、Settings の Conversations 節(§4.5)と同じ値を読み書きする。
  サイズが変わってもハイライト・カウンタの意味は変わらない(位置は文字単位で、描画サイズと無関係)
- **描画エンジン(右ペインのメッセージ面)**: アプリ同梱のページを表示する WKWebView(システム
  WebKit — 追加依存なし)。ヘッダ・検索バー行・Resume・一覧はネイティブのまま(§8.38)。規律:
  transcript 由来の文字列は **textContent 経由でのみ** DOM に入れる(HTML 文字列に混ぜない)/
  nonce 付き CSP で外部ロードと混入コードを遮断 / ページ遷移は全キャンセルし、本文中のリンクは
  既定ブラウザで開く / **意味論は Core が正**: 描画後テキスト・ヒット位置・畳み境界・バッジ件数は
  すべて Swift 側の計算値を渡し、ページは受け取った境界で切って描くだけ(JS では再計算しない)。
  配信の異常(サイズ待ちからの放流・自己修復・未 ack の再注入・WebContent プロセス死・JS エラー)は
  **既定レベルでログに残す**(正常系の毎回のログは持たない — 異常だけが自分で名乗る)
- **選択とコピー**: メッセージをまたぐ連続選択ができる(文書として扱う)。⏺ マーカー・
  展開/畳みボタンなどの操作部品は選択・コピーに含めない。**どちらのコピーも対象は選択範囲だけ** —
  選択が無ければ何もコピーできない。右クリックメニューは
  **Copy(⌘C 併記)/ Copy as Markdown(⇧⌘C 併記)の 2 項目を常に出し**、選択が無い間は
  両方 disabled(Look Up 等の標準項目は取り除く)。
  **⌘C / ⇧⌘C はペイン自身がキーを受けて処理する**(ビューの performKeyEquivalent はメニュー配達より
  先に走る — Edit メニュー(§4.5/§8.41)の Copy と二重処理にならない。§8.38)。
  **Copy = WebKit 標準のコピー(`copy:`)を呼ぶだけ** — 書式(リッチテキスト)も含めて
  WebKit に任せ、自前の書き出し経路を作らない(§8.38)。
  **Copy as Markdown = 選択範囲を、描画に使ったブロック構造とインラインスタイルから Markdown に
  直列化**したもの(見出し・リスト・コードブロック・表と、インラインの code・強調・打ち消し・
  リンクを復元する。原文の文字列一致ではなく「選択した部分の Markdown 表現」)。
  テストの検証点: ⌘C は**キーが `copy:` の呼び出しに届くこと**まで(WebKit 自体を再テスト
  しない)、⇧⌘C は**注入ペーストボードに直列化が載ること**まで(§8.38)
- **Resume ボタン**(実行できるのは past の行のみ。live では disabled — 上記): `shiibar-cc resume --cwd <cwd> <session_id>` を subprocess
  実行(アプリの操作は CLI 経由の原則 — §8.24)。ウィンドウは閉じない。成功直後に search を
  再実行する(再開した会話が running になり、Resume の出ない行に変わる)。再開された会話は
  SessionStart(resume) の hook で通常どおり Agents 一覧にも載る。
  **一覧の表示からクリックまでの時間差でよそで resume された会話への二重 resume は防がない**
  (意図的な割り切り。§8.34)
- **索引の温め**(表示とは独立の背景動作): アプリ起動時に `conversations index` をキック(失敗は
  静か — ログのみ)+ `NSBackgroundActivityScheduler` で約 10 分ごと(§9。§8.22 と同じ流儀)。
  目的は search 時の追いつきを常に小さく保つことで、表示の鮮度はこれに依存しない
- **ウィンドウを開いたとき**: `conversations index --json` を実行し、進捗(`Indexing N of M…`)を
  ステータス行に流す。完了したら空クエリ(または現クエリ)の search で一覧を出す。
  **全構築中は検索欄を無効にして進捗だけを見せる**(構築中の部分結果は見せない — §8.34)。
  index がエラー終了したら一覧を出さずステータス行にエラーを表示(次の契機で回復)
- **ステータス行(左下)**: `N conversations (M running)`、絞り込み中は `N of M conversations`、
  構築中は進捗、エラー時はエラー
- **アンインストール**: DB は状態ディレクトリ内なので、既存の一段アンインストール(§8.20)が
  そのまま消す。追加の削除対象はない

## 5. リポジトリ構成(monorepo)

全マイルストーン完了時点の構成。

```
shiibar/
├── Cargo.toml              # workspace
├── crates/
│   ├── shiibar-cc-proto/
│   ├── shiibar-cc-client/
│   ├── shiibar-ccd/
│   └── shiibar-cc/
├── app/                    # SwiftUI メニューバーアプリ(Swift Package。dev-install.sh が .app 化)
├── .claude-plugin/
│   └── marketplace.json    # リポジトリ = プラグインマーケットプレイス(§4.1)
├── plugin/                 # Claude Code プラグイン(hooks 配布。§4.1)
│   ├── .claude-plugin/
│   │   └── plugin.json
│   └── hooks/
│       ├── hooks.json
│       └── report.sh
├── scripts/
│   ├── dev-install.sh      # バイナリ配置 + .app 化(shiibar-ccd・shiibar-cc 同梱)+ CLI symlink + Login Items + プラグイン導入案内
│   ├── dev-uninstall.sh
│   ├── dev-reload.sh       # 開発中の daemon / app 差し替え(ドッグフーディング用)
│   ├── dev-demo.sh         # 偽 hook 再生でデモ用セッションを並べる(README スクリーンショット用)
│   ├── generate-app-icon.swift  # アプリアイコンの唯一の原本(bundle.sh が実行して .icns を生成・同梱)
│   ├── lib/                # スクリプト共有部(bundle.sh = .app 組み立て+署名の単一ソース、署名 ID 管理、アプリ/daemon 停止)
│   └── release/            # リリースビルド用(タグ⇔バージョン検査・署名付きビルド・リリースノート生成。§8.28)
├── fixtures/               # 実 hook JSON の採取物(M1 で採取・コミット。統合テストが再生する)
├── docs/
│   ├── DESIGN.md           # 本書(挙動の正)
│   ├── menubar-design.html # メニューバー確定デザイン(見た目の正)
│   ├── conversations-design.html # Conversations ウィンドウ確定デザイン(見た目の正。§4.6)
│   ├── DEVELOPMENT.md      # 開発メモ(手順・運用。実装の進行に合わせて追記)
│   └── tasks/              # マイルストーンごとの実装指示書(M1.md, …)
├── packaging/
│   └── homebrew/           # cask テンプレート(tap リポジトリへは bump-cask.yml が描画して push。§8.28)
├── .github/workflows/
│   ├── ci.yml              # push / PR で cargo test / clippy / swift build / swift test / cask style + cargo-deny(§10)
│   ├── release.yml         # タグ push → 署名・公証・staple → draft Release(workflow_dispatch = dry-run。§8.28)
│   └── bump-cask.yml       # release published → tap の cask を自動更新(§8.28)
├── deny.toml                       # cargo-deny 設定(advisories / licenses / bans。§10)
├── CLAUDE.md
├── LICENSE-MIT / LICENSE-APACHE
└── README.md
```

ライセンス: MIT OR Apache-2.0(デュアル)。

## 6. マイルストーン

各 M の完了条件は「自動テスト」と「実機スモーク(手動)」に分ける。

| M   | 内容                                               | 自動テスト                                                   | 実機スモーク                                   |
| --- | -------------------------------------------------- | ------------------------------------------------------------ | ---------------------------------------------- |
| M1  | proto + shiibar-ccd(report/list/subscribe/remove/seen/info/shutdown、state.json 復元、ログ。sessions は §8.15 で削除)+ `shiibar-cc report` + hooks | 遷移表(§3.4)のテーブル駆動テスト。fixtures 再生 → subscribe 出力列が期待と一致。daemon 再起動で状態復元 | 実セッションの遷移を watch で観測。実 hook JSON を fixtures/ に採取 |
| M2  | shiibar-cc-client + shiibar-cc(list/watch/wait/focus/focused/reconcile/remove/doctor)+ dev-install.sh(バイナリ + hooks。daemon は手動起動、.app は M4) | exit code 系統(wait: 0/1/2/124、focus: 0/1/2/3)。selector 解決。iterm モジュールの純関数部。reconcile の add/update/prune/flag | `wait . --status idle && say done` が動く。focus で該当タブが前面に来る。reconcile で幽霊が消え・見逃した waiting が復元。doctor が全項目 green |
| M3  | (削除)resume は実装後に不要と判明し機能ごと削除した(§8.15) | —                                                            | —                                              |
| M4  | メニューバーアプリ                                 | (UI は手動中心)                                              | アプリ起動で daemon 起動・既存 daemon へのアタッチ・Quit で daemon 停止・起動時/再接続時/手動 reconcile。ロールアップ表示・ドロップダウン focus・「再スキャン」。unreviewed 通知(遅延・前面抑制 — 前面抑制はその後廃止 §8.16)。focus で配信済み通知が消えること。切断中・権限 denied の警告行 |

M2 完了時点で日常投入を開始し、以降はドッグフーディングしながら M3/M4 を進める。

M5 以降のマイルストーンはこの表には足さない — 各回の範囲・完了条件・結果は `docs/tasks/` の
実装指示書(冒頭の Status 行が完了記録)に、そこで下した決定は §8 に記録する。

## 7. リスク・要検証事項(実装前に潰す)

1. **iTerm2 / AppleScript の実挙動** — ✅ 実機で検証済み(2026-07-04、M2 スモークで発見)。
   - `$ITERM_SESSION_ID` は `wNtNpN:UUID`、AppleScript の `id of session` は裸の UUID で UUID 部が一致
   - **`index of tab` は取れない**(`-1728`)。`index of window` と `id of session` は取れる → focused は UUID のみ返す
   - focus は **session(pane)も select** しないと分割ペインで違うペインに着地する(`tell s to select` 必須)
   - 分割タブの走査で `repeat with s in sessions of t`(plural)が **間欠的に `-1719`** → 明示 index + `try` で回避
   - **pid → tty(`ps`)→ iTerm2 の session tty 突き合わせ → UUID** で target を導出できる(reconcile の基盤。§3.5)
   - **`$ITERM_SESSION_ID` は iTerm2 から起動した他アプリに環境変数ごと相続される**(2026-07-05 実機確認:
     iTerm2 のタブから起動した VS Code の統合ターミナル内の claude に親シェルの値がそのまま残り、
     起動元タブの UUID を指していた)。一方 `TERM_PROGRAM` は VS Code が `vscode` で上書きする
     (iTerm2 直下は `iTerm.app`)→ **iTerm2 判定は `TERM_PROGRAM` + `ITERM_SESSION_ID` の同時チェック**で行う(§4.1)
   - **Mission Control の「アプリケーションの切り替え時に、アプリケーションのウインドウがあるスペースに移動」が
     OFF だと、focus の select + activate ではウィンドウのある Space / ディスプレイに切り替わらない**
     (2026-07-07、2 台目の実機で確認: TCC は許可済み・Setup Check 全緑でも focus が「効かない」見た目になり、
     ON に戻すと解消)。設定の実体は NSGlobalDomain の `AppleSpacesSwitchOnActivate`
     (明示 `0` = OFF。未設定は既定 ON)→ doctor がチェックする(§4.4)
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
   **AskUserQuestion のダイアログは、表示から 15 秒以内の遅延で Notification(message:
   "Claude needs your permission")を発火し、§3.4 どおり waiting + unreviewed になる**(放置実験
   3 サンプルで確認。いずれも表示から 15 秒以内に発火し、通知バナーも出た。回答・拒否で即 working に復帰)。
   表示直後は working のままなので、遅延より早く即答した場合のみ「あなたの番」を取りこぼす
   (窓は最大 15 秒程度。backstop は reconcile)。
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
5. **配布パイプラインの外部挙動** — ✅ 実測済み(2026-07-08〜09):
   - claude CLI(2.1.204)の plugin 更新は 2 段必要: `claude plugin marketplace update <name>` は
     マーケットプレイスのクローンを更新するだけでインストール済み plugin は変わらず、
     `claude plugin update <plugin>@<marketplace>` は手元のクローンからしか入れない →
     配達は `marketplace update` → `plugin update` の順で両方実行する(cask の postflight。§8.28)
   - **hardened runtime 下でも focus は動く(entitlement 不要と確定)**: 公証済みの v0.1.0(brew 版)の
     実機で、アプリ発の focus と CLI の TCC プローブがともに成功(2026-07-09)。Apple Events を送るのは
     子プロセスとして spawn した `/usr/bin/osascript` で、親が hardened runtime でも
     `com.apple.security.automation.apple-events` entitlement なしで通る。
     配布前は公式ドキュメントに規定が無く要実機検証としていたグレーゾーンの決着
   - notarytool の公証待ち(`submit --wait`)は、新規アカウントの初回提出で 2 時間超かかることがある(実測)。
     同一アカウントの 2 回目の提出は即時に近い(タグの run が全体 79 秒で完走。2026-07-08 実測)。
     `--timeout` はこちらの待ちを打ち切るだけで Apple 側の処理は続く(実物 help に明記)—
     打ち切っても提出は無駄にならず、あとから `notarytool info <id>` で確認できる。
     release.yml の待ち上限はこの実測を踏まえて余裕を取ってある(値は release.yml が正)
6. **transcript(会話ファイル)の構造** — 実測済み(2026-07-12〜13。M34 実装時に確定した項目を含む。
   未観測は末尾の 1 点のみ):
   - 場所は `~/.claude/projects/<cwd スラグ>/<session_id>.jsonl`。ディレクトリ 0700・ファイル 0600(実測)
   - 行の `type` は `user` / `assistant` / `system` / `file-history-snapshot` / `ai-title` / `last-prompt` /
     `attachment` / `queue-operation` など 12 種超(実測)。`ai-title` 行の `aiTitle` = `/resume` ピッカーが
     表示するセッションタイトル(1 ファイルに複数回現れる — 最後のものが現在値)。`last-prompt` 行の
     `lastPrompt` = 最後のユーザー入力
   - `user` / `assistant` 行は `cwd` と `.message.content`(文字列または block 配列)を持つ。
     発話テキストは生ファイルの約 2%(最大ファイル 12.4MB 中 280KB。残りはツール結果・スナップショット類)。
     全 300 ファイル(169MB)からのテキスト抽出は約 1.3 秒・抽出テキストの総量は 6.8MB =
     平均 約 23KB/ファイル(単スレッドの jq。2026-07-12)— 1 ファイルあたり平均数 ms・
     最大級(12.4MB)でも約 0.1 秒の換算
   - macOS 14.x 同梱の SQLite(3.43.2)に FTS5 + trigram あり(日英韓の部分一致を実測)。
     trigram の `remove_diacritics` オプションは 3.43.2 に無い(実測エラー)→ アクセント同一視は行わない
   - spawn 型のセッション(コーディネータが起動する類)は transcript を持たない(§7-3)→ Conversations には現れない
   - `user` / `assistant` 行は `uuid` / `parentUuid` を持つ(実測 2026-07-12)— **ファイルは追記専用の木**で、
     rewind は古い枝を残したまま過去の地点から新しい枝を伸ばす。アクティブな会話 = 現在の葉から
     `parentUuid` を遡った経路(§4.6 の抽出はこの経路のみ。葉の決定規則も §4.6)。
     **葉の規則は実物 93 会話で実証済み**(M34 実装時、2026-07-13): `leafUuid` と両方持つ 86 ファイル
     全部で両者は同一枝上・乖離ゼロ。うち 17 ファイルで `leafUuid` は葉の**祖先**(最後のユーザー
     入力)を指しており、leafUuid から素直に遡ると最後の回答が経路から落ちる — 採用した
     「最後の完全な user / assistant 行」規則が正しい。**system / attachment 行も uuid / parentUuid を持ち木に参加する**
     ため、遡行は全 uuid 行を対象にし、収集だけを user / assistant に絞る
   - **サブエージェントの会話は別ファイル**(実測 2026-07-13): `<スラグ>/<session_id>/subagents/` 配下
     (入れ子あり)にあり、実機の 317 jsonl 中 224 がこれ。スラグ直下(§4.6 のパス形)だけを掃引すれば
     除外される。トップレベル transcript の user / assistant 行は全行 `isSidechain: false`(実測)。
     **`isMeta: true`** は注入行(画像プレースホルダ・スキル指示文等)のマークで、発話から除外する
   - タイトル系の行は `ai-title`(`aiTitle`)と `custom-title`(`customTitle`)の 2 種(実測 2026-07-13、
     全 transcript の型集計)。**`custom-title` だけを持ち `ai-title` を 1 行も持たないセッションが実在する**
     (分岐時の自動命名と思われる "(Branch)" 付き)— タイトル導出は custom-title 優先(§4.6)。
     要約系の行は存在しない(TUI の放置時サマリは transcript・`history.jsonl`・セッション別
     ディレクトリのいずれにも永続化されていない — 実測で候補を掃引)
   - `~/.claude/sessions/<pid>.json`(§7-2)は実行中プロセスと 1:1 を実測(2026-07-12、
     2 ファイル vs 実行中 claude 2 プロセス。古いファイルの残留なし。セッション中も更新され続け、
     正常終了で消える — 過去多数のセッション終了後に残骸ゼロであることと整合)
     → live/past フラグの判定源に使う(§4.6)。
     **プロセス名の確認は argv[0] で行う**(実測 2026-07-13): `ps` の COMM 列 = argv[0] は `claude` だが、
     **libproc の `proc_name` / `p_comm` はバージョン文字列("2.1.207")を返す**(claude がプロセス
     タイトルを書き換えるため)。判定は `sysctl(KERN_PROCARGS2)` で argv[0] の basename を読む(実装済み)
   - FTS5 に bigram トークナイザは無い(実測エラー)が、**格納時に 2 文字ずつ分割 + unicode61 +
     フレーズ検索**で 2 文字クエリの索引検索が成立することを実測済み(2026-07-13)— 2 文字 LIKE が
     遅くなったときの乗り換え先(§8.34)
   - LIKE の実速度(2026-07-13、実 transcript 由来の 4,895 メッセージ・3.5M 文字で計測):
     2 文字 LIKE = 10ms / FTS MATCH = 1ms 未満。現規模では LIKE も知覚できない
   - **弁別規則(M34 実装時に実物で確定、2026-07-13)**: user 行は content が block 配列で
     `tool_result` block を含むなら丸ごと機械(text と混在する実例なし)。文字列 content の先頭タグ
     `<task-notification>` / `<command-name>` / `<command-message>` / `<local-command-stdout>` /
     `<local-command-caveat>` はスラッシュコマンド記録・自動 wake-up として除外。assistant 行の
     content block は `text` / `thinking` / `tool_use` / `fallback` の 4 種を実測 — text のみ抽出。
     `custom-title` と `ai-title` の**共存ファイルは実機に存在せず**(ai のみ 57 / custom のみ 1)、
     共存時の更新規則は未実測(custom 優先の規則をそのまま適用)
   - **観測未の残り**: `sessions/<pid>.json` のクラッシュ時の残り方のみ(read-only では再現不能。
     残っても 2 段生存チェックが無害化するため設計影響なし)

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

遅延通知・前面抑制は当初から意図した機能であり、v1 に残す(前面抑制はその後の実感で廃止した — §8.16。
resume は §8.15 のとおり実装後に削除した)。
`focus -`(ジャンプ元へ戻る)とメニューの「← 戻る」は 2026-07-05 のドッグフーディングで
「呼び出す自然な瞬間がない」(飛んだ先は Claude の画面でシェルがなく、キーバインドを組まない限り使えない)と
判明して削除した。再検討の条件: 帰り道が欲しい実感が出て、キーバインド等に割り当てる気になったとき
(実装は git 履歴にある。`last_focus` の保存ごと復活させる)。

### 8.11 iTerm2 外のセッションは追跡しない(フォールバック target を作らない)

- このツールの価値は「状態を見る + そのタブに飛ぶ」。iTerm2 外(VS Code ターミナル / SSH 等)のセッションは飛べないので、リストに出てもデッドウェイトにしかならない(設計原則 1「特化する」)
- iTerm2 のセッションと判定できない report(`TERM_PROGRAM` が `iTerm.app` でない、または `$ITERM_SESSION_ID` が無い。§4.1)は drop、reconcile は pid→tty が iTerm2 に一致しないセッションを skip する(§3.5)。結果 daemon が持つのは常に iTerm2 セッションだけ = 全部 focus できる。追跡しないので空 target の衝突も起きず、フォールバック target は不要
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
- 追記(2026-07-05): 最初に実際に欲しくなったツマミは「バナーと音を独立に止める」だった。設定画面ではなく
  Settings サブメニューの独立ミュート 2 スイッチ(Mute Banners / Mute Sound。§4.5)として追加。
  細分化は引き続き post-v1

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

### 8.16 通知の前面抑制を廃止した(M5)

- v1 は「配信直前に対象が前面なら通知しない」を持っていた(§8.10 で v1 に残すとした機能)が、
  2026-07-05 のドッグフーディングで「画面を見ていても手は別作業中で、音が鳴ってほしい」が実感となり廃止した
- 3 秒の遅延通知(発火時に unreviewed を再確認)は残す — 即応したときに通知を出さない仕組みはこちらで足りる。
  代わりに「対応した瞬間に配信済みバナーも消える」掃除(§4.5)が残骸を防ぐ
- 完了通知の音もこのとき追加した(waiting と同じ標準音・active レベル。ミュートは両方に効く)
- **再検討の条件**: 前面作業中の通知・音が「うるさい」実感に変わったとき。§8.14 の設定画面の
  ツマミ(レベル別オン/オフ)として戻すのが正しい形で、無条件の前面抑制には戻さない

### 8.17 セッションコスト表示は見送った(M5)

- ドロップダウンに Total Cost を出す案は、表示手段が無く見送った(2026-07-05)。
  フック(Stop / SessionEnd)は費用情報を運ばない(§7-3 と実 fixtures で確認)。
  transcript の解析は非公開仕様への依存になるためやらない(所有者決定)。
  statusline 連携(statusline スクリプトには `cost.total_cost_usd` が渡される)は
  「statusline を設定した人だけ動く機能」になるため採らなかった
- **再検討の条件**: statusline を常用する運用になったとき(そのときは statusline → daemon への
  報告口を §4.2 に足す形で設計する)

### 8.18 配布は「公証済み .app」を選択肢に含めて公開準備で決める(M5)

- ローカルビルド + 自己署名(§4.5)は自分専用の前提。公開時の配布形態は
  Developer ID 署名 + 公証(Apple Developer Program)を選択肢に含めて公開準備の中で決める
  (所有者は年会費を許容する意向。2026-07-05)。個人アカウントの Developer ID 証明書には
  登録者の本名が入る点は了解済み
- brew は cask(要・公証済みバイナリ)/ tap + formula(ソースビルド)の 2 形態がありうるが、
  需要が見えてから作る。v1 公開時の導入手順は clone + `scripts/install.sh` を README に書く
- Setup Check(導入チェック一覧の画面 — §4.5)は、将来のドロップ導入時に
  オンボーディング画面を兼ねられる構成にしておく

### 8.19 hooks は Claude Code プラグインで配布する(公開準備)

- `~/.claude/settings.json` への手動マージ(旧 `hooks/settings-snippet.json`)を廃止し、
  リポジトリ自体をマーケットプレイスにして(§4.1)`/plugin marketplace add` + `/plugin install` の
  2 コマンドで導入する。プラグインの hooks はユーザー設定と自動マージされ、settings.json を
  手編集させない・スクリプトで書き換えない、という M2 以来の制約を仕組みごと解消する(2026-07-05)
- `report.sh` はプラグインに同梱し `${CLAUDE_PLUGIN_ROOT}` で参照する。`~/.local/bin/report.sh` の設置は廃止
- 検討した代替: プロジェクト同梱の `.claude/settings.json`(そのリポジトリ内でしか効かず不適)/
  managed settings(組織 IT 配布用)/ 手動マージ(現行)。「全プロジェクト対象・手編集なし」を
  満たすのはプラグインのみ(公式ドキュメントで確認、2026-07-05)
- **再検討の条件**: プラグイン機構の仕様変更で hooks 同梱・`enabledPlugins` の形が壊れたとき

### 8.20 uninstall は一段のみ(`--purge` 廃止)(公開準備)

- 旧 `--purge` の内容(state dir / UserDefaults / 自己署名証明書 / iTerm2 TCC リセット)を既定にする。
  二段構えが守っていたのは「再インストール時の許可ダイアログ 2 回と Start at Login の再設定」だけで、
  install.sh がそれ以外を全自動で復元できる以上、「一時的に外す」段を分ける実需がない(2026-07-05)
- hooks の撤去はプラグイン管轄(`/plugin uninstall`)になり(§8.19)、settings.json 編集ロジックは削除する

### 8.21 バンドルのファイル名は表示名と一致させる(`Shiibar CC.app`)

- システム設定 > 通知 の一覧が、旧ファイル名 `ShiibarCC.app` のとき「ShiibarCC」と表示された。
  調査の結果、Info.plist・LaunchServices・ncprefs・通知 DB はすべて `Shiibar CC` で正しく、
  「ShiibarCC」はどこにも永続化されていない — 一覧が表示のたびに導出しており、この導出が
  ファイル名(拡張子抜き)にフォールバックしていた。プロセス再起動・LaunchServices 再登録・
  Spotlight 再インデックスでは直らない(2026-07-05 実機調査)
- フォールバックの発動条件(なぜ iTerm.app は `iTerm2` と出るのか)は特定できなかった。
  確実な対処は「どの導出経路でもファイル名が正解になる」こと、すなわちファイル名 = 表示名。
  macOS の一般的な慣習(`Google Chrome.app` 等)とも一致する
- 既存インストール環境でのリネームは ncprefs の path 書き換えを伴う(古い path のままだと
  通知バナーのアイコンが汎用になる。手順は DEVELOPMENT.md のアイコンの節)

### 8.22 reconcile の定期実行を有効化した(§8.10 の再検討条件が成立)

- §8.10 で「status ドリフトが手動リロードでは追いつかないと実感したとき」と予約していた
  定期 reconcile を有効化する(2026-07-07、ドッグフーディングで「working のまま固まる」を実感。所有者要望)
- 実装は `NSBackgroundActivityScheduler`(間隔 約 60 秒・tolerance 30 秒。§9)。1 回のコストは
  `claude agents` + osascript 走査で 1 秒未満・稼働率 1% 未満のため、間隔は修復の速さだけで選んだ。
  「見ていないときに走らせない」は自前の画面状態検知ではなく OS のスケジューラに委ねる
  (スリープ中は発火せず、復帰後に自然再開 — 復帰直後の 1 回が取りこぼし修復として最も効く)
- 定期実行はフィードバック表示なし(手動 Rescan と区別。§4.5)

### 8.23 コスト表示は引き続き見送る(statusline 連携案を棄却)

- §8.17 の再検討条件(statusline の常用)は成立したが、statusline 連携案そのものを棄却した
  (2026-07-07、所有者決定): statusline は全マシンに設定されているとは限らず、
  マシンによって動いたり動かなかったりする機能はこの道具の標準にできない
- hooks が費用情報を運ばないことを公式ドキュメントで再確認(2026-07-07。費用計測は OpenTelemetry 側の
  管轄で、hook payload には載せない意図的な分離)。transcript 解析をやらない判断(§8.17)も維持
- **再検討の条件**: hook payload が費用情報を運ぶようになったとき

### 8.24 ⌄ メニューに Clear badges と About を追加(§8.4 の例外を拡張)

- 「メニューバーには focus 以外の動詞を置かない」(§8.4)の例外を 2 つ増やす(2026-07-07、所有者要望):
  **Clear badges**(未読フラグの一括クリア。未読が溜まったとき 1 件ずつ focus して消すのは苦行)と
  **About**(アプリ名・アイコン・バージョンの確認先が無かった)。どちらも破壊的でなく確認フロー不要
- Clear badges は **unreviewed フラグだけ**を消し、通知センターの配信済み通知は触らない(所有者判断:
  通知は利用者が自分で消す。行クリックの focus がそのセッションの通知を消す挙動は従来のまま = 非対称は許容)
- CLI に `seen <selector>` を追加し、アプリは未読 target ごとにそれを呼ぶ(アプリの操作は CLI 経由、
  の原則を維持。§4.4)

### 8.25 既定ソートを Grouped にし、⌄ メニューをセパレーターで 3 グループ化した

- 既定の並びを Newest session から **Grouped** に変更(2026-07-08、所有者要望):
  一目で知りたいのは「どれが waiting か」で、Grouped がそれを最短で示す(README のヒーロー画像も
  Grouped)。Sort by ラジオの並びも既定を先頭に(Grouped / Newest session / Recent activity)。
  保存済みの並び設定がある環境では挙動は変わらない(既定はフォールバック値)
- ⌄ メニューをセパレーターで 3 グループに: **操作**(Rescan / Clear badges)/
  **表示と設定**(Sort by / Settings / Setup Check…)/ **アプリ自身**(About / Quit)。
  About は §8.24 時点では Settings の直後に置いたが、macOS の慣習(About は Quit と同じ最下段)に
  合わせて移動した。7 項目にセパレーター 2 本 — 刻みすぎない 2/3/2

### 8.26 Settings ウィンドウを追加した(§8.14 の再検討条件が成立)

- §8.14 で「実際にいじりたいツマミが見えたとき、そのツマミだけ足す」と予約していた設定画面を
  追加(2026-07-08、所有者要望)。見えたツマミ = **イベント別(Waiting / Done)の通知音の種類**
- 決定:
  - 音の候補は **macOS 標準サウンドのみ**(独自音源は同梱しない)。音は通知に付属させて鳴らし、
    Focus・おやすみモードに従う(§8.27)
  - **音量ツマミは見送り**(当初要望にあったが棄却): 通知付属音には音量の概念がなく、実現するには
    「音量を焼き込んだ音声ファイルをアプリが生成する」機構が要る。音の種類の選択で実質の音量調整も
    ある程度できるため、まず音種のみで始める。**再検討の条件**: 音種の変更では音量の不満が
    解消しないと実感したとき(そのときは焼き込み生成方式で設計する)
  - ⌄ メニューの Settings サブメニューは廃止し、スイッチ類ごとウィンドウへ移動
    (メニューは実行項目「Settings…」1 つに。メニューの並び・グループは §8.25 のまま)
  - **閉じるボタンは置かない**(即時反映で「OK で確定」が無い。赤ボタン + ⌘W。Setup Check と同じ作法)
  - 既定値(音 = 両方 Glass)は従来の聞こえ方を変えない
  - **ポップアップを閉じたまま ↑↓ でプレビューを切り替える案は棄却**: macOS はクリックでは
    コントロールにキーボードフォーカスを移さないため、クリックだけでは ↑↓ が届かない(Tab 前提の
    操作は求めない)。普通のポップアップ(クリックで開く→選ぶ→プレビュー)のみとする
- 見送り(§8.14 に挙がっていたが今回は要望が無い): イベント別の通知オン/オフ。シグナルが来たら足す

### 8.27 Mute Banners を廃止した(バナー制御は OS に委譲)

- M5 で作った独立ミュート 2 スイッチ(§8.14 追記)のうち **Mute Banners を廃止**(2026-07-08、所有者決定)。
  「音だけモード」(バナーなしで音だけ)はアプリが音を直接鳴らすため **Focus・おやすみモードに
  従わない唯一の経路**だったが、Focus 中に音を出すアプリは行儀として存在しない(所有者指摘)
- バナーだけ止めたい需要は **macOS のシステム設定 > 通知**(通知スタイル「なし」+ 音オン)が
  同じことを Focus 連動込みで正しく実現する — アプリ内スイッチは OS 機能の劣化コピーだった
- これによりアプリが音を直接鳴らす経路は消え、音はすべて通知付属に一本化
  (例外は Settings ウィンドウのプレビュー再生のみ — 利用者の操作起点なので直再生でよい)。
  **Mute Sound は維持**(「音だけ止める」はワンクリックの価値がある頻出操作。通知に音を付けないだけ)

### 8.28 配布は brew cask を正式経路にする(§8.18 の置き換え。配布マイルストーン M17–M20)

- 正式導入経路は自前 tap(`bufferings/homebrew-tap`)の cask。`brew install --cask bufferings/tap/shiibar-cc`
  で .app(`/Applications`)と CLI 2 本が入る(cask の `binary` stanza が .app 内 Helpers を brew の bin に
  symlink — hooks の PATH 問題を仕組みで解消)。§8.18 の「v1 公開時の導入手順は clone + install.sh」は
  これで置き換え。ソースビルドは開発者向けに残す(`dev-install.sh` / `dev-uninstall.sh` に改名)
- リリースはタグ push → Actions で arm64 ビルド → Developer ID 署名(hardened runtime)→ 公証 → staple →
  zip → **draft** Release → 所有者の実機スモーク後に publish → `release: published` で tap を自動 bump
  (公開済み資産から sha256 を再計算)。「push = 公開の前に所有者スモーク」の原則をタグ配布にも適用した形
- arm64 のみで **Intel はサポートしない**(検証する実機も CI も無いため約束しない。ソースビルドを Intel の
  代替として案内しない)。再検討の条件: Intel での検証手段を得たとき
- hooks plugin は cask の postflight で自動インストール(初回ガード付き — `enabledPlugins` にエントリが
  あれば新規インストールはせず、upgrade での再実行や意図的に外した plugin の復活を防ぐ。claude 不在・
  失敗時は install を壊さずスキップ)。自動で入ることは README と caveats の両方に明記する
- **hooks 更新の配達も postflight が担う**: エントリがあり**有効**(`true`)なら
  `claude plugin marketplace update shiibar-cc` → `claude plugin update shiibar-cc@shiibar-cc` を
  この順で実行する(実測 2026-07-08・claude 2.1.204: marketplace update はクローンの更新のみで
  インストール済み plugin は更新されず、plugin update は手元のクローンからしか入れない — 両方必要。
  いずれも best-effort。brew upgrade でアプリと hooks が揃い、利用者の auto-update 設定に依存しない。
  反映は次セッションから)。無効(`false`)なら何もしない — 切った人の選択を尊重(初回ガードと同じ思想)
- plugin は Release の zip ではなくリポジトリ main から入る。**hooks はサポート中の最古のリリース
  バイナリと後方互換を保つ**こと(report.sh が「バイナリ不在なら黙って exit 0」の薄い転送層であることが前提)
- バージョン運用: Cargo.toml の version は常に「次に出す番号」(publish 直後に bump)。dev ビルドは
  `-dev` を付けて名乗る。公開後のタグ再利用は禁止。
  **plugin.json の version だけはタイミングが異なる**: リリースコミットまで前リリースの番号を保つ
  (bump = 配布のゲートなので、先に上げるとサイクル途中の hooks 変更が中途半端に配布される。§4.1)。
  タグ時点で tag = Cargo.toml = plugin.json が一致していることを `check-version.sh` が検査する
- 受け入れた既知のギャップ: cask uninstall で daemon が生き残り得る・Login Item のゴースト表示
  (いずれも無害・自己修復)/ `brew upgrade` 時に旧 daemon + 新アプリが一時混在し得る
  (再検討の条件: リリース間でプロトコルを変えるとき)
- curl|sh 方式は不採用(更新が `brew upgrade` に乗る方を優先。両者は同じ公証済み zip の上の薄い層なので、
  需要が見えたら後から足せる)

### 8.29 記号系を本家 TUI の語彙に統一した(M22・M24)

- ドロップダウン行・トレイ・アプリアイコンの記号を、Claude Code の TUI が実際に表示する語彙
  (グリフ循環スピナー `·✢✳✶✻✽` / 静止した `✻` / `!`)に統一した(2026-07-08〜09、所有者決定)。
  従来のリング・円弧・点灯ドットは「どのアプリにもある借り物の幾何学」で、見た目の物足りなさの
  正体は由来の無さだった — 見張っている対象と同じ記号なら説明なしで読める
- 決定の要点:
  - **行**: idle = 薄い `✻`(静止)/ waiting = 輪郭吹き出し + `!` / working = グリフ循環スピナー。
    動きは本家実装から読み取ったコサインイージング(周期 2 秒。§9)。
    等間隔ステップは明滅として知覚されるため不採用。`✻` の回転も文字グリフの光学中心のずれで
    軸ぶれして見えるため不採用(いずれも実機確認で棄却)
  - **トレイ**: 「窓 + 左上スロットの 1 グリフ」に還元。waiting はスロットの `✻` を太い `!` に
    入れ替える(あなたへの要求が窓に立つ)。右下の点灯ドット・`!` は廃止
  - **アプリアイコン**: 窓タイル + `✻`(左上 1/4 の中央)+ 右肩赤バッジ。状態記号の縦積みは廃止。
    バッジは「ターミナルエミュレータではなく見張り」を一言で伝える(ターミナル系アイコン文法との
    誤読防止)
  - 紋章のグリフは `✳`(U+2733)→ `✻`(U+273B)に統一
- 状態への色は D 案(waiting のみ琥珀)まで検討して棄却 — 「色は赤ただひとつ = あなた宛の未読」の
  1:1 の意味論を守る方を選んだ
- ブランド上の配慮は従来方針の継続: 素の Unicode 文字グリフをシステムフォントで描くのみで、
  Anthropic のロゴ資産・サンバースト形状・ブランド色には寄せない(menubar-design.html の実装ノート)。
  Claude Code 起動画面のブロックアートを使う案は商標リスクで棄却
- **再検討の条件**: working の瞬きやトレイの `!` 入れ替えが、実運用で煩さ・誤読を生んだと
  実感したとき(トレイの点灯ドット復活は小さい変更で戻せる)

### 8.30 一覧ウィンドウを追加し、窓がある間だけ通常アプリになる(M26–M27)

- §8.3 の再検討条件が成立(2026-07-09、所有者の実運用フィードバック: 一覧をずっと表示して
  おきたい)。ドロップダウンと同じ一覧をタイトルバー非表示の普通のウィンドウとしてピン留め
  できるようにした(M26。挙動仕様は §4.5)。最前面固定・全 Space 追従・位置記憶は
  「窓に居座られる」方向の性質としてすべて不採用
- **窓に ⌄ を置かない**: 毎日見続ける面に低頻度の操作(Rescan / Settings / Quit 等)が常駐して
  場所を取るのはおかしい、という所有者の指摘から。操作の置き場所は「窓が存在する間だけ
  通常アプリになり、アプリメニューに出す」(M27)。メニューバーにメニューを出すことと Dock に
  載ることは macOS 上不可分なので、「窓を使っている間だけ Dock にいる」を許容する判断をした。
  常時通常アプリ化は「Dock に入るほどのアプリではない」で棄却
- メニューはアプリメニュー 1 個のみ(File / Edit / Window は出さない。⌘W は Close Window 項目で
  担保)。ドロップダウン ⌄ の並び順をアプリメニューと統一 — 同じ操作の並びが器ごとに違うと
  覚え直しになるため。⌄ 固有の Open as Window はアプリメニューの Close Window に当たる位置に
  置き、最終グループを「窓の動詞 + Quit」に揃える(窓の動詞だけが器で入れ替わる)。
  これにより §8.25 の 3 グループ構成(操作/表示と設定/アプリ自身)は
  この並びに置き換わる(セパレーターによるグループ化自体は維持)
- Appearance 設定(System / Light / Dark)を Settings > General に追加 — 常時表示する窓は
  夜の見え方が品質の一部になるため(OS はライトのままアプリだけダーク、を可能にする)
- **再検討の条件**: 窓を閉じている時間にも Dock・⌘Tab・メニューが欲しい実感が出たとき
  (そのときは常時通常アプリ化を再検討する)

### 8.31 並び順を「新しいセッション順」に一本化した(M28)

- 一覧ウィンドウの実運用(2026-07-09)で、並び順まわりの分かりにくさの源が
  「開いた時点で並びを固定する」付属ルールにあると判明した。このルールは Recent activity
  (キー = `last_report_at` が動き続ける)のためだけに存在していた
- **Recent activity を廃止**し、Sort by を Grouped / Newest session の 2 択にした。
  順序凍結の仕組み(開いた時点で確定・窓の毎分の並び直し・開いている間の新セッション末尾追加)は
  存在理由が消えるため一式撤去。並びの説明は「新しいセッション順。Grouped はそれを状態で
  仕切ったもの」の 1 文になった。失うのは「最後に触ったセッションが上に来る」並びだが、
  注意が要るものは Grouped の waiting が先頭に出し、ジャンプは通知・赤バッジ起点なので
  実利の場面が思い当たらなかった
- **Grouped のグループ内も新しいセッション順にし、unreviewed の上寄せをやめた**。
  上寄せには「focus して確認するとフラグが下りて行が落ちる = 見たことで並びが変わる」性質があり、
  出しっぱなしの窓では目につく。フラットモードには「位置では示さない(太字 + 赤バッジで足りる)」
  判断が既にあり(§4.5)、Grouped だけ位置でも示すのは理屈が割れていた
- `last_report_at` はプロトコル・daemon 状態には残す(UI の消費者が消えただけ。
  §4.2 の配信頻度の削減までは踏み込まない — Rust 側は無変更)
- 保存済みの `recentActivity` 設定は、未知値の既定フォールバックで Grouped に落ちる(§4.5)
- **再検討の条件**: 「最後に触ったセッションを一覧の上で拾いたい」場面が繰り返し出たとき

### 8.32 高さの規則: 一時的な器は中身が決め、常駐する器は人が決める(M29)

- 大量のセッションを開いたときの見え方の検討(2026-07-09)から。従来は両方の器が
  「一覧の上限高 360pt(実機調整値)+ スクロール」だった
- **ドロップダウン**: 中身のぶんだけ伸び、ディスプレイの可視領域で頭打ち → スクロール。
  メニューバー由来のメニューが画面いっぱいまで伸びる macOS 標準の振る舞いに一致。
  ユーザーによるリサイズは無し(メニューはリサイズしないもの)
- **一覧ウィンドウ**: 縦のみユーザーリサイズ可・高さを記憶(幅は 340 固定 — 行のデザインが
  340 前提)。中身に高さを決めさせないのは、セッションの増減で常駐ウィンドウが勝手に
  伸縮すると挙動が予測できないため(画面の下寄りに置くと伸びたぶんがはみ出す等)。
  位置を記憶しないのとは対照的に高さは記憶する — 位置は「開いたら右上」という規則が
  価値だが、高さに毎回戻ってほしい既定値は無い
- **再検討の条件**: 窓の高さも中身に追従してほしい実感が出たとき

### 8.33 Keep on Top をオプションとして追加した(M30)

- §8.30 は最前面固定を不採用としたが、あれは**既定の挙動**としての判断だった(頼んでいないのに
  居座られるのがうざい)。実運用で「並行作業が重い時間帯だけ上に居てほしい」という
  状況依存の需要が出た(2026-07-10、所有者)ため、**既定 OFF のトグル**として追加。
  ON にするのは利用者の明示的な操作なので、§8.30 の判断と矛盾しない
- 置き場所はアプリメニュー(Settings ウィンドウではなく)— 状況で切り替える性質の
  スイッチなので、窓を使っている最中に届く場所に置く。値は記憶する
- 変えるのはウィンドウレベル(floating)だけ。全 Space 追従は引き続き不採用(別種の押し付けがましさ
  なので混ぜない)
- **再検討の条件**: ON のまま忘れて他の作業の邪魔になる報告が繰り返されたとき
  (そのときは「窓を閉じたら OFF に戻す」等の自動リセットを検討)

### 8.34 Conversations(会話の一覧・検索・閲覧・再開)を追加した(M33–M35)

- §8.15 の再検討条件が成立(2026-07-12、所有者): 「あの会話の続きをやりたいが、どのフォルダだったかを
  探して回る」が実運用で繰り返し発生。`claude -r` はディレクトリ単位でしか引けず、フォルダ横断の探索が
  欠けていた。形も §8.15 が予約したとおり「いまの状態ビューとは分けた別一覧から開き直す」(§4.6)
- **§8.17 の「transcript 解析はやらない」をこの機能に限り変更**: 「末尾を読みたい」「本文で検索したい」は
  hooks が運ばない情報で、transcript を読む以外に満たせない。
  読み取り専用・専用モジュールへの局所化・壊れるのは表示だけ・README に依存を明記、の条件で受け入れる。
  コスト表示をやらない判断(§8.17/§8.23)自体は不変。ベータ表記は付けない(所有者判断 —
  依存の告知は README の一文で行い、看板にはしない)
- **名前は Conversations**(2026-07-13、所有者): resume の付属機能として始まったが、設計の過程で
  「眺める・探す・読む」が resume と並ぶ独立の価値だと判明し、動詞(Search 等)ではなく対象物の
  名前にした。索引が持つのはセッションの記録から**会話(人の発話と Claude の返答)だけを抜き出したもの**
  なので、Sessions より Conversations が正確(`claude --help` 自身も "Resume a conversation by
  session ID" と、会話 = 中身 / session ID = 識別子の使い分けをしている)。Settings と Sessions の
  見間違い問題も同時に消えた。CLI(`conversations`)・DB ファイル名まで揃える。短縮エイリアスは
  実感が出たら足す
- 切り離しは構造で担保する: daemon・プロトコル・hooks・状態モデルは無変更。Rust 側の追加は
  CLI `resume`(§4.4)+ iterm モジュールの `open_resume_window`(§4.3)+ conversations モジュール
  (索引・検索。下記)
- **索引と検索は CLI(Rust)に置く**(2026-07-12、所有者): 「スクリプトから会話を検索したい」が
  要件と宣言され、消費者が UI と CLI の 2 人になった(§8.2 の原則 — 実物 2 例が揃ってから境界を
  作る — のとおり)。当初はアプリ内(Swift)案だったが、Swift に置くと CLI 検索を後から足すコストが
  高い(再実装か私有スキーマの文書化)非対称があり Rust に決定。**境界は各コマンドの出力 JSON**で
  DB スキーマは私有(NDJSON プロトコルと同じ関係)。アプリはキー入力(デバウンス後)ごとに
  subprocess を起動して検索する — 起動 10〜30ms 程度で知覚できず、focus / reconcile と同じ作法。
  依存に rusqlite(libsqlite3-sys)を追加し、リンク先は macOS 同梱の libsqlite3(バンドルしない。§10)
- **索引は全会話 + live/past フラグ、ウィンドウも live を出す**(2026-07-12〜13、所有者):
  「過去だけの索引」はデータ層に UI の都合を焼き込む形で、live フラグ付きの全体を返し、絞るのは
  消費者の責任にする。名前から Past が消えた時点で「検索したのに実行中が出ない」は名前で説明できなく
  なり、ウィンドウにも live の行を出す(`running` の淡いテキスト印・アクションなし — Resume と
  別動詞の混在を作らない。実行中の会話への動詞は実感が出たら設計する)。
  終了時の一括抽出も生存中の逐次取り込みに分散して消える
- **search は「常に transcript の現在に対して答える」**(2026-07-13、所有者): 検索という道具は
  結果の不在を信じられなければ意味がなく、「index を先に呼んだかどうかで結果が変わる」隠れ状態
  依存を作らない。DB は**アクセス時に自己更新される内部キャッシュ**と位置づけ、search は追いつきを
  内蔵する(`git status` が stat キャッシュを実行のたびロック付きで更新するのと同じ、実証済みの
  パターン)。追いつき中の他プロセスとは flock で調停し、**待つ**(黙って古い結果を返す経路を
  持たない)。全構築中だけは検索を提供しない(部分結果 + 不完全マーカーの機構は、マシンごとに
  一度きりの場面に対して過剰と判断)
- **live/past の判定は `~/.claude/sessions/` の pid ファイル**(2026-07-13、所有者):
  当初 daemon の一覧(iTerm2 のみ — §8.11)→ `claude agents --json`(ターミナル非依存だが実測
  0.25〜1 秒の Node 起動)と変遷し、最終的に claude agents の情報源そのもの(§7-2)を直接読む。
  1ms 級になり、search の追いつきに毎回含められる。生存は `kill(pid, 0)` + プロセス名 = `claude` の
  2 段チェック(レジストリはファイル名 = pid なので、pid 再利用は新しい claude の上書きで自己解決 —
  §4.6)。`claude agents` はこの機能から退場(reconcile では従来どおり使用)
- **抽出はアクティブ経路のみ・変更ファイルは全読み直し**: 現在の葉から `parentUuid` 遡行 —
  rewind で捨てた枝を索引・表示に入れない。葉は `last-prompt` の `leafUuid` ではなく**「ファイル内で
  最後の完全な非 sidechain の user / assistant 行」**(leafUuid が最後のユーザー入力を指す場合、素直に遡ると最後の回答が
  経路から抜け落ちる — 追記専用の木では最後に追記されたノードが常にアクティブ枝上にあるので、
  こちらが構造的に正しい)。ファイル内の追記差分管理はしない(平均数 ms・最大 0.1 秒の実測 —
  §7-6 — に対して、枝の付け替えの追跡機構を持つ複雑さが釣り合わない)
- **表示の更新はすべて利用者起点**(2026-07-13、所有者): 開いたとき / 打鍵 / ⟳ ボタン / 自分の
  Resume 直後、の 4 契機のみ。「検索していないのに結果が変わる」驚きを作らない。当初案の FSEvents
  常時監視 → ウィンドウ表示中のみ → フォーカス時 refresh、と削っていき、search の自己追いつきが
  確定した時点で**監視そのものが不要**になった(索引の鮮度は表示の鮮度と無関係になったため)。
  daemon に監視を置く案も棄却(daemon はアプリと同じライフサイクル — §8.8 — で常駐性の利点が出ず、
  更新をアプリに伝えるプロトコル拡張が要り、壊れ得る transcript ドメインを中核に持ち込むため)。
  背景に残るのは索引の温め(起動時キック + 約 10 分ごと)だけで、これは速度の最適化であり
  正しさに関与しない
- **閲覧は全文一括 + 文書内ヒットナビゲーション**(2026-07-13、所有者): 発話テキストは平均
  23KB・最大 280KB(§7-6 の実測から)で、選択時に全文を取得して遅延描画で出せる規模。
  当初の「末尾数往復 + 読み足しリンク」は resume 前の末尾確認が目的だった時代の設計で、
  「読む」が目的に昇格した時点で全文一括に置き換えた(範囲指定 API・読み足し状態・位置ずれの
  問題が一式消える)。複数ヒットは文書内検索の標準 UX(全ハイライト + カウンタ + ▲▼)で、
  初期位置は**最新のヒット**(検索の手がかりは最近の記憶であることが多く、同じ語なら終盤の方が
  結論に近い — 所有者)。search 結果のスニペットは持たない(選択 = 即全文プレビューの世界では
  クリック前の選別の価値が薄い。再検討の条件: ヒットの選別でクリックの往復が苦になったとき —
  後から足すのは前方互換)
- **検索語は 2 文字から**(2026-07-13、所有者): trigram は 3 文字未満を索引で引けないが、日本語は
  2 文字の語が普通に検索語になるため、2 文字の語は LIKE(唯一の LIKE 経路)で支える。1 文字の語は
  無視し、有効な語が無ければ検索しない(UI は発行せず、CLI は exit 1 — 黙って 0 件を返さない)。
  **再検討の条件**: 2 文字検索が体感で重くなったとき — 乗り換え先は格納時ビグラム化
  (手法実測済み — §7-6。スキーマ版の自動再構築で移行できる)。「3 文字に絞る」方向には直さない
- **複数語は AND**(2026-07-13、所有者): 空白区切りの複数語は「全語を含む会話」に絞り込む。
  OR は語を足すほど結果が増え、インクリメンタル検索の「打つほど目当てに近づく」文法に
  逆行するため不採用。実装は語ごとに独立のクエリ(2 文字 = LIKE / 3 文字以上 = MATCH)で会話の
  集合を取りコードで積集合 — 語の長さの組み合わせによる場合分けを持たない(所有者案)。
  語数の上限は設けず、クエリは直列(LIKE 実測 10ms/語・MATCH 1ms 未満 — §7-6 — で、上限にも
  並列化にも守るものがない)。クエリは前後 trim(全角空白含む)。空白を含む連続文字列そのものの検索(フレーズ)は持たない —
  **再検討の条件**: フレーズで探したい実感が繰り返し出たとき(FTS5 のフレーズ構文が受け皿になる)
- 再インデックスは自動のみ(差分更新 / スキーマ版不一致で全再構築 / 破損検知で作り直し)。
  手動の再インデックス UI は置かない — 利用者が「押すべき場面」を判別できる状況が自動処理と
  重ならないため。逃げ道は DB ファイル(状態ディレクトリ内 — §2)の削除(DEVELOPMENT.md に記載)。
  DB が状態ディレクトリに居るので、アンインストールも既存の一段削除(§8.20)がそのまま面倒を見る
- **最低 OS を 13 → 14 に引き上げ**: Ventura のセキュリティ更新は 2025 年秋に終了(公開情報で確認)。
  検証機も無く、パッチの出ない OS を約束しない(Intel 非対応 — §8.28 — と同じ理屈)。
  14+ なら同梱 SQLite の trigram が保証になり、トークナイザ不在へのフォールバック実装が不要になる
- **二重 resume は残る時間差の分だけ許容する**: 一覧の表示からクリックまでの間によそで resume された
  会話を画面から resume すると、同じ session ID の 2 プロセス目が立ち得る。`claude` 自身が
  実行中セッションの resume を拒否しない(所有者の観測)ため既存挙動への新しい入り口にすぎず、
  クリック時の再照合を足すコストと釣り合わない。§8.7・§8.12 と同じ「穴があっても平気な作り」の
  割り切り。**再検討の条件**: 二重 resume で実害(transcript の破損等)を実際に踏んだとき —
  そのとき `shiibar-cc resume` に実行前の照合(live なら拒否)を足す
- **機能全体の再検討の条件**: transcript のフォーマット変更による修理が繰り返し必要になったとき
  (Claude Code が公式のセッション一覧・履歴 API を出したらそちらへ乗り換える)。フレーズ検索・
  実行中の会話への動詞(Focus / fork)・スクロール記憶の永続化は実運用のシグナル待ち

### 8.35 Conversations ウィンドウを「読む画面」として再設計した(M36)

M35 の実機スモークで所有者から「見た目が読みにくい」「畳みの中のヒットが見えない」
「文字サイズを変えたい」が出て、右ペインを素のテキストの羅列から読む画面へ再設計した
(2026-07-13〜14、所有者)。挙動仕様は §4.6、見た目の正は conversations-design.html。

- **自分の発言 = 全幅の帯、Claude の発言 = Markdown 描画**: この画面の主活動は「自分の短い指示 →
  Claude の長い返答」の繰り返しを読むこと。自分の発言は本文ではなく見出しとして全幅の帯
  (背景の明度差のみ・`❯` + 通常ウェイトの発言 — Claude Code のターミナル表示と同じ文法)にし、
  会話全体を「何を頼んだか」の目次として流し読みできるようにする。Claude の返答は元々 Markdown
  なので描画する — 素のテキスト表示が読みにくさの主因だった。役割ラベルの行(You / Claude)は
  帯と地の文の対比で不要になり廃止
- **棄却した右ペイン案**(いずれも所有者判断): 右寄せバブル(技術的な長文で左右往復が読みにくい)/
  帯への色付け — 琥珀のアクセント(色面が好みに合わない。無彩の明度差で足りる)/
  太字の見出し(帯が見出しの仕事をするので文字を強めない)/ Claude 側のインデント
  (帯だけで区別が足りる)/ 全文モノスペース切り替え(Markdown 描画でコードが常にモノスペースに
  なり実需が消えた — 残る需要が出たら §8.10 と同じ「実害が出たら足す」扱い)
- **一覧の行は「時刻を 1 行目の右端」**(Messages / Mail の文法)+ ホバーのハイライト。罫線・
  ゼブラ・時間のグループ見出し(Today 等)は棄却 — 現代の会話リストの主流は罫線を引かず、
  区切りは行の内部構造とホバーで読ませる。時間見出しは行ごとの経過時間表示と情報が重複し、
  所有者が不要と判断
- **クロームはフルハイトサイドバー**: 信号機をサイドバーの上に載せ、サイドバー素材の色を
  ウィンドウ上端まで通す(System Settings と同じ形)。読む面(右ペイン)は通常のウィンドウ背景で、
  帯・コードブロックの明度差が立つ。一覧ウィンドウの「信号機の帯」との差は意図的
  (あちらはアイコン直下の一時的な器、こちらは独立した読む窓)
- **ヒットの所在を常に見せる**: スクロールバー相当位置のヒット目盛り(分布 + 現在位置)と、
  畳みの展開ボタンの件数バッジ(`N matches`)。「カウンタには数えられているのに画面のどこにも
  見えないヒット」を無くす。展開の対(`Show less`)も追加
- **ハイライトの位置計算は描画後テキストが対象**: 会話の絞り込み(CLI・生テキスト)と文書内の
  位置決め(アプリ・表示テキスト)を分離する。Markdown 記号にだけヒットした会話は本文ヒット 0 件と
  表示される — 見えている文字が正
- **文字サイズは ⌘+ / ⌘− / ⌘0 + Settings の Conversations 節**(11〜18pt・既定 13pt)。
  ツールバーの Aa ボタン案は棄却(ツールバーは検索と ⟳ だけに保つ。発見性は Settings と
  ショートカットで足りる)。アプリの UX 設定カテゴリ(§8.9)なので UserDefaults
- **再検討の条件**: Markdown 描画で表示が壊れる実例が繰り返し出たとき(フォールバックは素のテキスト
  表示)/ 帯だけでは長い返答の途中で迷う実感が出たとき(そのとき初めてインデント等の補助を再検討)

### 8.36 Claude の発言の先頭に ⏺ マーカーを付けた(M37)

M36 の実機スモークで「1 つの指示に Claude の発言が連発すると境目が読めない」が出た(2026-07-14、
所有者)。索引は自動 wake-up・ツール実行を除外するため、エージェントが長く走ったセッションでは
発言の連発が普通に起きる。発言間の余白だけでは段落間と区別できない。

- **すべての Claude の発言の先頭に淡い ⏺**(Claude Code のターミナルが発言の頭に付けるのと同じ文法。
  帯の `❯` と対になる)。連発時だけ出す条件分岐はしない — いつも同じ場所にある印だけが境目として
  学習できる。状態の意味は持たない(色分けしない)
- **ぶら下げ**(折り返しがマーカーの下に回り込まない)を採用し、行頭インライン案は棄却 —
  インラインは折り返し行がマーカーの下に潜って境目の効きが弱く、コードブロックで始まる発言で
  置き場所が不自然になる。ぶら下げは帯の `❯` とグリフ列が揃い、画面が「グリフ + 本文」の
  2 列グリッドになる
- ⏺ は描画後テキストに含めない(「⏺」で検索してもヒットしない。畳み境界にも数えない)
- **「指示 + 発言一式を単位として畳む」案は見送り**: 畳みは単位の先頭を見せるため、最新の単位まで
  畳むと「最後どうなったかを見て再開する」流れで結末が既定で隠れる。まず ⏺ で境目を解く。
  **再検討の条件**: ⏺ を入れても「単位で畳みたい」実感が残ったとき — そのとき「最新の単位だけ
  既定で展開」とセットで設計する

### 8.37 パイプ表を描画範囲に加えた(M38)。Markdown は自前描画を続ける

M36 が表を描画範囲外(素のテキストのまま)としたところ、実データで Claude が表を多用し、
生のパイプ記号は壊れて見えることが実機で判明した(2026-07-14、所有者)。

- **パイプ表をネイティブのグリッドで描画する**(ヘッダ強調・行間罫線・左揃え・セル内インライン有効・
  内容幅 + 横スクロール。§4.6)。等幅整形(列幅を空白で揃えてコードブロックの器に載せる)案は棄却 —
  モノスペースフォントに日本語グリフが無く、フォールバックした CJK の幅が揃わないので列が崩れる。
  セル内のインラインも効かず、整形用の空白が描画後テキスト(検索対象)に混ざる
- **Markdown 描画ライブラリは採らず、自前のブロック分解を続ける**(2026-07-14、所有者):
  この画面の難所は描画そのものではなく、その上の自前仕様(任意文字範囲へのハイライト注入・
  描画後テキスト基準の畳み・⌘ズーム連動・⏺ グリッド)にある。レンダラ系ライブラリは描画後テキストの
  オフセット取得や任意範囲の背景色注入の口が無く、簡単な部分を肩代わりして難しい部分を塞ぐ。
  調査時点(2026-07-14)で MarkdownUI はメンテナンスモード宣言済み(後継 Textual へ移行)。
  自前なのはブロック分解だけ(インラインは Apple 標準の `AttributedString(markdown:)`)で、
  Swift 側のサードパーティ依存ゼロ(§10 の依存最小)も保てる。
  **再検討の条件**: 描画範囲を GFM 全体へ広げたくなったとき — 乗り換え先は swiftlang の
  swift-markdown(パーサ。cmark-gfm ベースで表も解析できる。調査時点で活発にメンテ)一択とし、
  レンダラ系は採らない

### 8.38 右ペインのメッセージ面を WKWebView にした(M39)

M36〜M38 の SwiftUI 描画に対して所有者から読み味の指摘が続き
(メッセージをまたぐ選択ができない・インライン code に padding が付けられない・行間が狭い・
表のセルが折り返さない・Markdown でコピーしたい)、うち 2 つ(またぎ選択・インライン padding)は
SwiftUI の `Text` では構造的に不可能だった。所有者の発案で HTML 描画を検討し、
スパイクで実証してから採用を決めた(2026-07-14、所有者)。

- **右ペインのメッセージ面だけを WKWebView にする**(§4.6)。システム WebKit なので追加依存は
  ゼロ(§10 は無傷)。ヘッダ・検索バー行・Resume・一覧・Settings はネイティブのまま
- §8.5(Tauri ではなく SwiftUI)とは矛盾しない: あの決定の前提「webview を描く場面がない」は
  メニューバー UI の話で、Conversations で「文書を読む面」が生まれた時点でこの面には
  当てはまらなくなった。アプリの器・通知・常駐は native のまま
- **スパイクの実証**(実データ最大 415 メッセージ・描画後 147k 文字): 初回表示 584ms(温まり
  ~367ms)・打鍵ごとのハイライト再描画 64〜69ms・WebContent プロセス約 100MB(窓の存在中のみ)。
  指摘 5 件は合計 10 行程度の CSS で解消。`<script>` 入りの会話が文字として表示されることを確認
- **意味論は Core が正のまま**: ヒット・畳み・バッジは M36〜38 の計算(テストで固定済み)を
  ページに渡し、JS では再計算しない。境界のオフセットは Core の書記素数から UTF-16 に変換して渡す
  (JS 文字列は UTF-16 — 絵文字で全ハイライトがずれるのをスパイクで検出・解決済み)
- **セキュリティ規律**(依存を持ち込んだ側の責務): 本文は textContent 経由のみ / nonce 付き CSP /
  ナビゲーション全キャンセル(リンクは既定ブラウザ)/ 非永続データストア
- **採用に対する反論も記録する**: +100MB のプロセスと、自分で持ち込んだ分のセキュリティ面、
  `swift test` の外の JS 層を、「読み味の紙傷 5 件」のために足すのか — という見方はあり得た。
  採らなかった理由: この画面の主活動が「読む」であり、指摘が読み味に集中し続けたこと、
  5 件中 2 件は native では構造的に直らないこと、見た目の正(conversations-design.html)と
  実装の乖離が構造的に消えること
- コピーの当初の文法: 右クリック = **Copy(⌘C)/ Copy as Markdown(⇧⌘C)** の 2 項目。
  「表示どおり」と「原文」の 2 動詞で、選択なしの Copy as Markdown はカーソル下のメッセージ
  (実機スモークで手直し — 下記。現行の文法は §4.6)
- **実機スモークからの手直し**(2026-07-14、所有者): (1) メニューの Copy は **WebKit 標準の
  項目をそのまま使う** — 自前の複製が選択検出の失敗で disabled のまま重複表示され、⌘C を塞ぐ
  事故が出た。(2) **Copy as Markdown を「触れたメッセージ丸ごと」から「選択範囲の直列化」に変更**
  — 選択より多くコピーされるのは驚きだった。原文からの切り出しは描画テキストと文字の対応が
  取れないため、描画に使ったブロック構造からの書き戻しで「選択したものが Markdown として
  出てくる」を実現する。(3) CJK 句読点隣接で `**` が素のまま見える(標準パーサの flanking 規則)
  — 保守的な補完で描画する(§4.6)。(4) テストが実ブラウザで example.com を開いていた —
  外向きの動作は注入可能にしてテストはスパイで検証し、フィクスチャの URL は実在しない予約
  ドメイン(example.invalid)を使う。一般則は CLAUDE.md の実装ルールに追加。
  (5) 2 巡目: それでも ⌘C が効かなかった — このアプリは標準メニューを全部空にしている
  (§4.5・M27)ため、**⌘C を配達する Edit > Copy のメニュー項目が存在しない**。
  「⌘C は WebKit が面倒を見る」は未検証の仮定だった。ペイン自身の performKeyEquivalent で
  ⌘C を受けて `copy:` を送る(⇧⌘C と同じ経路)。教訓: コピー動線はショートカット押下から
  ペーストボードまでの端到端テストを必須にする(検証点は (6) で改めた)。合わせてメニューは所有者判断で
  **Copy / Copy as Markdown の 2 項目のみ**に(Look Up 等の標準項目は取り除く —
  読む画面に置く動詞を 2 つに絞る)。
  (6) 3 巡目: (5) の「ペーストボードの中身まで検証」の縛りが**機能を削っていた** —
  WebKit の `copy:` は本物のクリップボードにしか書けないため、テスト可能性を優先して
  自前のプレーンテキスト専用経路が作られ、リッチテキストが落ちた。所有者指摘
  (「テストのために機能を避けてるってこと?」)で主従を正す: **機能が先、テストは機能に従う**。
  ⌘C は WebKit の `copy:` を呼ぶだけに戻し(書式込みのコピーがそのまま手に入る・自前経路を
  持たない)、テストの検証点は「キーが `copy:` に届くこと」までに改める — 呼び出し先の
  フレームワークを再テストしない。⇧⌘C(自前機能)の中身検証は従来どおり。
  合わせて所有者判断で**選択なしのコピーを全廃**(カーソル下メッセージの原文コピーを削除 —
  「選択していなければ何もコピーできない」の方が説明不要)。メニューは常に 2 項目・
  選択なしは両方 disabled(1 巡目の disabled 事故の真因は Edit メニュー不在であり、
  disabled 項目自体は無害)
  (7) 4 巡目: 検索バー行の ▲▼(裸の山形 2 つ + `2/5`)が「押せる感じも向きの意味も
  伝わらない」— **macOS 標準の文書内検索の文法**(`N of M` + ‹ › セグメンテッド + ⌘G / ⇧⌘G)に
  寄せる(§4.6)。ヒット 1 件だと再スクロールしない実装も判明し「押下のたびに現在ヒットへ
  スクロール」を仕様に明記。合わせて所有者要望で**サイドバー幅を境界ドラッグで可変**に
  (初期 250pt・200〜400pt・幅を記憶 — §9。固定幅は初期値に格下げ)
  (8) 5 巡目: 検索バーのセグメンテッドコントロールがペイン全幅に伸びる事故 —
  「コントロールは内容サイズ・左寄せ」を明文化。‹ › は端で折り返す(⌘G の慣習・所有者確認)。
  ヘッダ下の区切り線は検索バーの有無によらず常時。running の会話で下部パネルごと消していたのを
  「常に出して Resume を disabled + 理由の一言」に(§8.34 の「アクションなし」の趣旨 —
  動詞を増やさない — はそのままで、表示の形だけ変更 — パネルが消えるとレイアウトが跳ねて分かりにくい、
  所有者指摘)。⟳ は押下の反応を必ず見せる(実行中 disabled + `Refreshing…`)。サイドバー境界は
  ホバーでリサイズカーソル + 境界線を濃く(掴めることが見た目で分かる)
  (9) 初回描画が真っ白のまま(操作すると回復)という報告 — 監視機構(未 ack 検知・プロセス死・
  JS エラー)は沈黙しており、既定レベルの計装を仕込んでから現場ログで確認したところ、
  **ビューが実サイズを得る 12ms 前に読み込みが走り、ページが 0×0 の viewport にレイアウトを
  済ませて「描画完了」を申告し、WebKit が以後再描画しない**競合だった。対策は構造的に:
  サイズゼロ・未接続の間は送信を保留して最初の実サイズ獲得で放流 + ack の viewport が 0 なのに
  実サイズがあるときは一度だけ自己修復(いずれもログあり)。教訓 2 つ: **現場診断のログは
  既定レベルに置く**(debug は現場の log stream にすら乗らないことがある)/
  **異常が自分で名乗るログ**なら正常系の記録は不要
  (10) ⟳ の「実行中は Refreshing…」は検索が数十 ms で終わるため知覚できず「反応がない」と
  再報告された — Rescan の文法(結果の 2 秒表示 — §9)に合わせ、完了後に
  `Updated · N conversations` を 2 秒出す
  (11) メニュー再編(§8.40)の実装が**起動時に毎回クラッシュ**した — AppMenuModel の初期化が
  `NSApp.keyWindow` に触っており、AppDelegate 生成時点では NSApplication が未初期化で即死。
  テストは起動経路を通らず素通り(同じ教訓は通知センターの遅延初期化として既にコード内に
  記録されていた)。対策: 初期化はグローバルに触らない(初期値 false + 窓イベント通知で更新)+
  実際の AppDelegate 構築連鎖を組み立てる回帰テスト。**起動生存チェックの自動化は所有者判断で
  見送り** — 「そのためのスモーク」(起動確認は所有者スモークの役割)
  (12) 「レフトナビ」がヒットせず「レフト」はヒットする — 診断の連鎖:
  ① 同一バイナリ・同一 DB で CLI は両方ヒット → GUI 側と確定
  ② アプリのパイプライン再現テスト 4 本は健全。一時は「IME の確定イベント取りこぼし」を
  疑ったが、**ペーストでも外れる**報告で棄却
  ③ 検索経路の計装ログ(内容を記録しない設計のまま)で「5 文字で発行 → exit 0 →
  空の結果」と特定 ④ NFD(分解形)のクエリで CLI が空を返すことを実証 — **真因は Unicode
  正規化**。「ビ」= ヒ + 結合濁点(NFD)はバイト列照合の FTS で合成形の索引と一致しない。
  「レフト」は濁点を含まず NFC = NFD なので当たっていた。
  対策: **CLI がクエリと索引本文の両方を NFC に正規化**(スキーマ版更新で自動全再構築 —
  入力経路によらず当たる)+ Swift 側も送信前に NFC 正規化(防御)+ 未確定(marked text)中は
  検索を発行せず確定で必ず発行(UX — ひらがなの中間状態で無駄な検索をしない)。
  教訓: 照合の同一視を決めるときは、大文字小文字・アクセントと別軸で**正規化(正準等価)**を
  明示すること
- **再検討の条件**: WebKit の更新で表示・選択が壊れる事象が繰り返したとき / メモリが実害になった
  とき — 戻し先は M36〜38 の native 実装(コミット 3fa4515)が土台として残っている

### 8.39 ミニマップ = スクロールバー、下端の手がかり(M39)

「開くと一番下(最新)から始まることが画面から読み取れない」という所有者の指摘から出発し、
所有者の発案(VS Code の全体図)をこの画面向けに翻案して採用した(2026-07-15、所有者)。

- **略図方式**: 縮小テキスト(VS Code 方式)は DOM 複製が要り最大級の会話で重い。描画に使っている
  ブロック構造と実レイアウト座標から矩形を描くだけの略図にする(詳細は不要と所有者確認)。
  帯 = 濃い縞が「会話の目次」として全体図に見える
- **スクロールバーと合体**: ミニマップを OS スクロールバーの左に並べる案は「つまみ」と「現在範囲」の
  二重表示になるため棄却。ミニマップ自体をスクロールバーにする(VS Code と同じ) —
  半透明グレーの帯がつまみ(当初の青い枠は棄却)、右ペイン内の OS スクロールバーは非表示
- **常時表示・幅 20pt**(14 / 20 / 26 の試作比較で所有者選択)。ヒット分布の目盛り(§8.35)は
  ミニマップ上の線として吸収
- **下端の手がかり**: 終端マーカー(`Latest message · <経過時間> ago`)+ 上端のスクロールシャドウ。
  「↑ N earlier messages」のフローティングピル案は棄却(数秒で消える = 常設の手がかりにならない)
- **計装ログの整理**: 真っ白問題(§8.38(9))の解決後、正常系の毎回のログ(送信・ack)は削除し、
  異常系(保留からの放流・自己修復・再注入・プロセス死・JS エラー)だけを既定レベルで残す —
  §8.38(9) の教訓「異常が自分で名乗るログ」の形
- **タイポグラフィは見た目の正に一致させる**: 実装が「詰まって読みにくい」と実機で判明 —
  行間・段落間・ブロック間隔・帯の余白は conversations-design.html の CSS 値が正で、
  実装側の目視合わせではなく値の一致で担保する。Resume ボタンのサイズも同様

### 8.40 メニュー再編: 窓の動詞の島と Agents の名前(M39)

Conversations ウィンドウの追加でメニューの文法が崩れていた(2026-07-15、所有者):
「Open as Window」(動作の名前)と「Conversations…」(対象物の名前)が並んで不一致になり、
アプリメニューでは Agents 専用の項目と窓の動詞が区切りなく混在して「Close Window が何を
閉じるのか読めない」状態だった。

- **一覧ウィンドウの表向きの名前を Agents に確定**(ウィンドウの `title` は元々 Agents)。
  メニュー項目は **Open as Window → Agents…** に改名し、Conversations… と同じ
  「対象物の名前 + …」の文法に統一。あわせて Agents… をアプリメニューにも置く
  (これまで ⌄ 固有だった)。docs の日本語の説明語「一覧ウィンドウ」はそのまま
  (製品面の名前が Agents、という関係)
- **島は機能別ではなく動詞の種類別**: 「窓を開く動詞の島」(Agents…・Conversations…・
  アプリメニューでは Close Window も)を独立させ、Quit と同居させない。機能別
  (Agents の島・Conversations の島)にまとめる案は棄却 — 同種の動詞が散る・
  Close Window の置き場が宙に浮く・窓が増えるたび島が増える。View / Window メニューを持つ
  macOS アプリの標準的な分かれ方と同じ構図
- **アプリメニューの Agents 専用項目(Rescan・Clear badges・Sort by・Keep on Top)には
  セクション見出し「Agents」**を付けて所属を見せる(見出しなしで Keep Agents on Top に
  改名する案は棄却 — 他の項目の所属が読めないまま)。⌄ メニューは Agents ビューそのものの
  上に開くので見出し不要
- Close Window は「閉じられる窓が無ければ disabled」に(常に有効な項目が何もしないより正直)

### 8.41 Edit メニューを復活させた(M39)

「メニューはアプリメニュー 1 個のみ」(§8.30・M27)は Agents 窓だけの時代の決定で、当時は
テキスト入力が存在しなかった。Conversations の検索欄で「⌘V も ⌘A も効かない」が実機で判明
(2026-07-15、所有者)— macOS の標準ショートカットは**メニュー項目の key equivalent 経由で
配達される**ため、Edit メニューを消したアプリでは全テキスト欄で死ぬ(WebView の ⌘C —
§8.38(5) — と同じ穴のテキスト欄版)。

- **Edit メニュー(標準項目のみ)を復活**: Undo / Redo / Cut / Copy / Paste / Select All。
  項目は標準のレスポンダチェーン任せ(自前ハンドラを持たない)。File / Format / View /
  Window / Help は引き続き出さない — 「消せるものは消す」の趣旨は保ち、実用に必要な 1 本だけ戻す
- 所有者判断は「入れて動きを見る」— 使用感に問題があれば §8.30 の形へ戻して
  ウィンドウ側のキー処理で個別に配達する案(WebView の ⌘C と同じ方式)に切り替える
- あわせて **⌘F = Conversations の検索欄へフォーカス**(§4.6)

## 9. 定数表

| 定数                         | 値                   | 変更手段                 |
| ---------------------------- | -------------------- | ------------------------ |
| 状態ディレクトリ             | `~/.local/state/shiibar-cc/` | `SHIIBAR_CC_STATE_DIR` |
| ログレベル                   | info                 | `SHIIBAR_CC_LOG`            |
| hooks 送信タイムアウト       | 1 秒                 | 固定                     |
| stale 閾値                   | 24h                  | 固定                     |
| reconcile 定期間隔           | 約 60 秒(tolerance 30 秒。`NSBackgroundActivityScheduler`) | 固定 |
| 通知音の既定                 | Waiting / Done とも Glass | Settings ウィンドウ      |
| stale スイープ周期           | 60 秒 + 起動時       | 固定                     |
| アプリ再接続バックオフ       | 1 秒 → 倍々 → 上限 30 秒 | 固定                 |
| 遅延通知                     | 3 秒(発火時に再確認) | 固定                     |
| task(prompt)の切り詰め      | 先頭 80 文字         | 固定                     |
| last_assistant_message の切り詰め | 先頭 200 文字   | 固定                     |
| Rescan 結果の一時表示        | 2 秒                 | 固定                     |
| working スピナーの周期       | 2 秒(グリフ循環 `·✢✳✶✻✽`・コサインイージング・50ms 刻み) | 固定(本家 TUI の実測値) |
| 一覧の幅                     | 340pt(ドロップダウン / 一覧ウィンドウ共通) | 固定      |
| ドロップダウン下端の余白     | 12pt(可視領域に収める際に残す。§8.32) | 固定           |
| 一覧ウィンドウの最小高さ     | コンテンツ 150pt ≈ 3 行(信号機の帯は OS が上乗せ) | 固定 |
| 一覧ウィンドウの経過時間再取得 | 60 秒(表示中のみ)  | 固定                     |
| wait の既定タイムアウト      | なし(無限待ち)       | `--timeout`              |
| Conversations 窓の初期サイズ | 640×480pt。縦横リサイズ可・サイズと位置を記憶 | 固定 |
| Conversations サイドバー幅  | 初期 250pt・境界のドラッグで 200〜400pt に可変・幅を記憶 | ドラッグ |
| Conversations ミニマップ    | 幅 20pt・常時表示。スクロールバー兼用(右ペイン内の OS スクロールバーは非表示)。本文の文字はミニマップ手前 8pt で折り返す(背景は変えない) | 固定 |
| Conversations ⟳ の結果表示  | `Updated · N conversations` を 2 秒(Rescan の一時表示と同値) | 固定 |
| Conversations 本文の文字サイズ | 既定 13pt・範囲 11〜18pt(⌘+ / ⌘− / ⌘0。コードブロックは本文 −1.5pt) | Settings ウィンドウ / ⌘ ショートカット |
| メッセージの畳み             | 先頭 500 文字(描画後テキスト)を超えたら畳む(`Show full message` / `Show less`。DB は全文) | 固定 |
| UI 検索のデバウンス          | 200ms(`conversations search` の subprocess 起動前) | 固定 |
| 検索語                       | 2 文字から・語数上限なし(1 文字の語は無視。2 文字 = LIKE / 3 文字以上 = FTS MATCH。複数語は AND) | 固定 |
| 索引の温め                   | アプリ起動時 + 約 10 分ごと(tolerance 5 分。`NSBackgroundActivityScheduler`) | 固定 |
| index 進捗イベントの間引き   | 100 ファイルまたは 250ms ごと | 固定             |
| 会話索引 DB                  | 状態ディレクトリ内 `conversations-index.db`(dir 0700 / DB 0600) | `SHIIBAR_CC_STATE_DIR` |

## 10. サプライチェーン対策

依存は少数の主要クレート(serde / serde_json / tokio / anyhow / tempfile、
M34 から rusqlite + libsqlite3-sys — 会話索引 §4.6。**システム同梱の libsqlite3 に
リンクし、`bundled` は使わない** — SQLite 本体をサプライチェーンに持ち込まない。
M39 から unicode-normalization — 検索の NFC 正規化 §8.38(12)。正準正規化表は自作しない類いの
もので、unicode-rs の標準実装・推移依存は tinyvec と tinyvec_macros の 2 つ)のみ。現状は
`Cargo.lock` をコミット済み。過剰にはせず、**適用済み**と明記したもの以外は
シグナル待ちで段階導入する:

- **依存 cooldown(pnpm の minimum-release-age 相当)**: cargo 純正の `cargo-min-publish-age`
  (`~/.cargo/config.toml` の `[registry] global-min-publish-age` + `[resolver] incompatible-publish-age`。
  Cargo.lock 固定済みの版は対象外)の **stable 化を待つ**方針(2026-07-04 調査時点で stable 未到達・状況が流動的。
  採用時に rustup / 公式で現物を再確認すること)。急ぎで欲しくなったらサードパーティ `cargo-cooldown`
- **CI(`ci.yml`)には最初から入れてある**: `--locked` でのビルド・テストと `cargo-deny`
  (advisories / licenses / bans。設定は `deny.toml`)。cargo-vet は個人用・小規模には過剰なので採らない
- **GitHub Actions の `uses:` はフルコミット SHA で固定する**(タグはコメントで併記。
  `owner/action@<40 桁 SHA> # vX`)。ci.yml / release.yml / bump-cask.yml の全 `uses:` に適用済み。
  release.yml のジョブは notarization の一時キーチェーンや .p8 鍵など secrets を扱う時間帯があり、
  そこで動く action がタグ参照だと上流の差し替えで任意コードが実行され得るため
- **GitHub リポジトリ側の保護(適用済み)**: main への force-push・ブランチ削除の禁止
  (shiibar-cc / homebrew-tap 両方)と、`v*` タグの削除・更新の禁止(§8.28 の「公開後のタグ
  再利用禁止」のプラットフォーム側強制 — 公開済みリリース資産の差し替えを塞ぐ)。
  Dependabot(alerts + security updates)と secret scanning + push protection も有効。
  設定の一覧と運用(PAT の期限対応を含む)は DEVELOPMENT.md「リポジトリ設定と Secrets の運用」
