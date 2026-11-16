# shiibar-cc 設計書

> menu bar agent status & jump for Claude Code + iTerm2 / Terminal.app

## 1. 目的

Claude Code のエージェント状態(working / waiting / idle と、未確認フラグ。§3)を macOS メニューバーで
常時可視化し、通知や、ポップオーバーとウィンドウの一覧(§4.5)から該当する
対応ターミナル(iTerm2 / Terminal.app)のタブへジャンプできるようにする。同じ一覧で過去の会話を
検索して読み、再開・分岐できる(§4.6)。
CLI(`shiibar-cc`)は hooks とアプリをつなぐ**裏方**(report / focus / reconcile / resume / conversations / doctor)であり、
利用者向けの表面はメニューバーと通知に集約する(`wait` / `watch` などのスクリプト利用も可能だが主役ではない)。

### 設計原則

1. **特化する**: Claude Code 専用・対応ターミナル(iTerm2 / Terminal.app。§8.47)専用。
   speculative generality は書かない
2. **意味の局所化**: 外部依存(ターミナルの ID 形式、AppleScript)を知るコードは `shiibar-cc-client` の
   ターミナルモジュール(iterm2 / apple_terminal)に閉じ込める。抽象化レイヤーは作らないが、汚染も広げない
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

- **target は prefix つきの不透明文字列**(`<ターミナル名>:<セッション識別子>`)。2 種類:
  - `iterm2:<UUID>` — UUID は `$ITERM_SESSION_ID` の `:` 以降。位置プレフィックス `wNtNpN` は**含めない** —
    hooks(report)と reconcile(iterm2_targets)が同一セッションに**同じ target を導出できる**ことが
    突き合わせ(§3.5)の前提で、AppleScript からは wNtNpN を再現できない(§7-1)ため
  - `apple-terminal:<tty パス>` — 例 `apple-terminal:/dev/ttys006`。Terminal.app では tty が
    「中(hook の環境)と外(AppleScript)の両方から同一セッションに導出できる」唯一の鍵(§7-7。
    `TERM_SESSION_ID` は AppleScript 側に対応物が無く使えない)
  - prefix は**ターミナル名フルネームの小文字ハイフン**(略語にしない — 人間が手打ちする場面が無く、
    自己記述性だけが価値。§8.47)。ターミナルが増えたら同じ規則で 1 種類ずつ増える
  - shiibar-ccd は解釈せず保持・転送するだけ。意味を知るのは shiibar-cc-client の
    ターミナルモジュール(iterm2 / apple_terminal)と、target を生成する `shiibar-cc report` のみ
  - **旧形式からの移行**: prefix 導入前の state.json は無印 UUID(iTerm2)を持ち得る。daemon は
    state 読み込み時に `:` を含まない target へ `iterm2:` を前置する(保存形式の 1 回きりの移行。
    target の意味の解釈ではない)
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
| `working` | 実行中(あなたの番ではない)   | 紋章 `✻` と 3 つの点(静止)/ グリフ循環スピナー |
| `waiting` | 許可・入力待ち(あなたの番)   | 紋章スロットに太い `!` / 輪郭の吹き出し + `!` |
| `idle`    | 待機中                       | 静止 `✻`・全体 0.8 / 薄い `✻`(静止)    |

表示に status の色は使わない(**赤は unreviewed 専用**)。見た目の正は、トレイアイコンが menubar-design.html、一覧の行が window-design.html。

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

「—」は status 変更なし(hook 由来の行は last_seen だけは更新する — §3.6。**seen 行は
last_seen も更新しない** — §4.2)。「登録」列は未登録 target の新規作成。
**対応ターミナルのセッション(§4.1 の 2 分岐で target を導出できたもの)だけを追跡する** —
target を導出できない report は drop し、フォールバック target は作らない(§8.11)。

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

gather は client 側(ターミナルモジュール。§4.3)、適用は daemon の `reconcile` コマンド(§4.2)。client は
`claude agents --json` を実行し、各セッションについて:

1. **target を導出**: `pid → tty(`ps`)` を取り、**起動中の対応ターミナル**の走査結果と突き合わせる —
   iTerm2 のセッション tty に一致すれば `iterm2:<UUID>`(§7-1)、Terminal.app のタブ tty に一致すれば
   `apple-terminal:<tty パス>`(§7-7。`ps` の tty は `/dev/` 無しなので前置して正規化する)。
   どちらにも一致しなければ **skip**(対応ターミナル外は追跡しない。§8.11・§8.47)。
   未起動のターミナルには AppleScript を投げない(is-running 照会は起動を誘発しない。§7-7)—
   未起動 = そのターミナルのセッションは存在しないので、空の走査結果と同じ扱いでよい。
   **試みた走査のいずれかが失敗/不完全なとき(-1719 等。§7-1)は、その回は prune を行わない**(生存確認できないものを消さない。
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
  / `created_at`(登録時刻。不変 — Running の区画の並びのキー。§4.5)
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
- **target の生成規則**(§2 の 2 種のどちらかを導出し、どちらも作れなければ **report を drop する** —
  飛べないので追跡しない。§8.11・§8.47。フォールバック target は作らない):
  - `TERM_PROGRAM` が `iTerm.app` で、**かつ** `$ITERM_SESSION_ID`(形式 `wNtNpN:UUID`。§7-1)があれば
    `iterm2:<UUID>`(`:` 以降の UUID。reconcile が AppleScript から導出する target と一致させるため。
    `wNtNpN` は含めない。§2)。`ITERM_SESSION_ID` の有無だけでは判定しない —
    iTerm2 から起動した VS Code 等に相続されて残り、起動元タブの UUID を誤って指すため(§7-1)
  - `TERM_PROGRAM` が `Apple_Terminal` なら `apple-terminal:<tty パス>`。tty は**自プロセスの制御端末では
    取れない**(hook プロセスは端末から切り離されて起動される — `ps` で `??`。§7-7)ため、
    **親方向に最初に制御端末を持つプロセスまで辿って取る**(実測では 2 段目の claude 本体が持つ。
    上限は §9 — 上限まで見つからなければ drop)。`TERM_SESSION_ID` は判定にも target にも使わない
    (AppleScript 側に対応物が無い。§7-7)
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
// complete = 試みたターミナル走査がすべて完全だったか。false(または欠落)なら prune を行わない(§3.5)
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
- `shiibar-cc-client`: socket 接続、list / subscribe / wait のクライアント実装と、
  **ターミナルモジュール(iterm2 / apple_terminal)**
    (モジュール名は target の prefix と同名 — ハイフンは Rust の識別子制約でアンダースコアになる)
  - `wait` は subscribe 1 本で実装する(最初に snapshot が来るので、別途 list を叩く必要はない)
  - **ターミナルモジュールの共通規則**: 各ターミナルの知識(ID 形式・AppleScript)はそのモジュールに
    のみ存在させる。target の prefix(§2)で同名のモジュールに振り分ける入口を 1 箇所だけ持ち、
    trait 等の抽象層は作らない(§8.2 — 実物 2 例の共通部分は「対になる 4 関数」
    (focus / focused / <ターミナル>_targets / open_resume_window)までで、それ以上を固定しない)。
    **振り分けの規則**: `iterm2:` → iterm2、`apple-terminal:` → apple_terminal。`:` を含まない target は
    `iterm2:` とみなす(§2 の移行前の値・手打ち UUID の互換。アップグレード前に配信済みの
    通知が持つ旧 target もこれで飛べる)。prefix 部が `wNtNpN` 形式なら `:` 以降を UUID として
    iterm2 に渡す(`$ITERM_SESSION_ID` を手で貼る利用の互換)。それ以外の未知 prefix は「該当なし」
    (exit 2 系統 — 黙って iterm2 に流さない)。
    **テスト分離**: AppleScript ソースの生成と osascript 出力のパースは純関数として切り出し、
    osascript プロセス実行部だけを差し替え可能にする(両モジュール共通)
  - **iterm2 モジュール**(iTerm2 の知識はここにのみ存在させる)
    - `focus(target)`: target(振り分け入口で `iterm2:` を外した裸の UUID。§2)を使い、
      AppleScript で iTerm2 の windows→tabs→sessions を走査し、一致を見つけたら
      **`activate` してから** window・tab・session(pane)を select する(activate が後だと、
      別アプリがアクティブな状態からの focus で今の Space のウィンドウが select に勝ち、
      別 Space へ遷移しない — §7-1)。一致なしは「該当なし」(activate は一致分岐の中のみ —
      該当なしでは何も動かさない)。
      **iTerm2 が起動していなければ起動せずに「該当なし」を返す**(走査は `application "iTerm2" is running` ガード内)。
      走査は明示 index + `try`(分割ペインで `index of tab` / plural 反復が `-1719/-1728` になる実機バグ回避。§7-1)
    - `focused()`: iTerm2 が最前面アプリのとき、前面 session の target(`iterm2:<UUID>`。§2)を返す。前面でなければ「なし」
    - `iterm2_targets(pids)`: **reconcile 用**。渡された pid(`claude agents --json` 由来)を `ps` で tty に引き、
      iTerm2 の各セッションの tty と突き合わせて `{pid → target(`iterm2:<UUID>`)}` を返す(§3.5 / §7-1)。
      iTerm2 に無い pid は返さない(iTerm2 外 = このモジュールの追跡外)
    - `open_resume_window(cwd, session_id, fork)`: **Resume と Branch 用**(§4.6)。新しい iTerm2 ウィンドウを
      開き、cwd で `claude --resume <session_id>` を実行する(`fork` が真のときは、コマンドの末尾に
      `--fork-session` を追加する — §4.4)。focus と違い **iTerm2 が起動していなければ
      起動する**(新しいウィンドウを開く動詞なので)。cwd・session_id は AppleScript / シェルの文字列として
      正しくエスケープする。起動方式は **`write text`**(新しいウィンドウの対話シェルに打ち込む):
      rc ファイルを通った利用者本来の PATH で `claude` を解決するため(version manager の shim や
      alias 経由でも動く)。`create window ... command` の直指定はログインシェルの PATH 構築を
      迂回するため採らない
  - **apple_terminal モジュール**(Terminal.app の知識はここにのみ存在させる。実測の根拠は §7-7)
    - `focus(target)`: target(`apple-terminal:` を外した tty パス)を使い、AppleScript で Terminal.app の
      **全 windows × 全 tabs** を走査し、`tty of tab` が一致したタブを **`activate` してから**
      `set selected of t to true` + `set frontmost of w to true` で前面化する(activate 先行の
      理由は iterm2 と同じ — §7-1。Terminal.app での Space またぎも実測済み — §7-7)。
      一致なしは「該当なし」(activate は一致分岐の中のみ)。
      **Terminal.app が起動していなければ起動せずに「該当なし」を返す**(is-running ガード。iterm2 と同じ)。
      全走査が必須なのは、Cmd+T のタブが AppleScript には**別 window(各 1 タブ)**として見える一方、
      Merge 等で 1 window 複数 tab の形も存在するため — 両形態を同じループがカバーする(§7-7 実測)
    - `focused()`: Terminal.app が最前面アプリのとき、前面 window の selected tab の target
      (`apple-terminal:<tty パス>`)を返す。前面でなければ「なし」
    - `apple_terminal_targets(pids)`: **reconcile 用**。渡された pid を `ps` で tty に引き、Terminal.app の
      各タブの tty と突き合わせて `{pid → target(`apple-terminal:<tty パス>`)}` を返す(§3.5)。
      `ps` の tty は `/dev/` 無し・AppleScript は `/dev/` 付き(§7-7)なので前置して比較する
    - `open_resume_window(cwd, session_id, fork)`: 新しい Terminal.app ウィンドウで cwd の `claude --resume` を
      実行する(`fork` の扱いは iterm2 と同じ)。起動方式は **`do script`**(新しいウィンドウの対話シェルにコマンドを打ち込む —
      iterm2 の `write text` と同じく rc を通った PATH で `claude` を解決するため)。
      Terminal.app が起動していなければ起動する(iterm2 と同じ「開く動詞」の例外)。
      エスケープ規則も iterm2 と同じ
    - split pane(Cmd+D)は同一セッションの表示分割で独立した tty を持たない(§7-7 実測)ため、
      pane の概念はこのモジュールに存在しない
  - osascript の TCC(オートメーション)権限エラーは「該当なし」と区別して呼び出し元に返す(両モジュール共通)

### 4.4 shiibar-cc(`crates/shiibar-cc`)

```
shiibar-cc report <event>     # hooks 専用: stdin の hook JSON を整形して daemon に送信(M1 で前倒し実装)
shiibar-cc list [--json]      # 非 --json は「状態 / ラベル / 経過時間 / target」の整列テキスト
shiibar-cc wait <selector> --status waiting|idle|working [--timeout SEC]
shiibar-cc watch              # subscribe のイベントを行 JSON で標準出力へ
shiibar-cc focus <selector>   # ジャンプ。成功時: daemon に seen を送る
shiibar-cc focused            # 前面の対応ターミナル(iTerm2 / Terminal.app)の前面セッションの target を出力(なければ exit 2)
shiibar-cc reconcile          # claude agents + ターミナル走査(iterm2_targets / apple_terminal_targets)を gather → daemon に reconcile を送る(§3.5)。アプリが起動時・再接続時・定期(§4.5)・手動 Rescan で呼ぶ
shiibar-cc remove <selector>  # 幽霊エントリの手動削除(通常は reconcile が自動で消す)
shiibar-cc seen <selector>    # unreviewed フラグを消す(daemon に seen を送る。アプリの Clear badges が target ごとに呼ぶ。§4.5)
shiibar-cc resume --cwd <dir> [--terminal iterm2|apple-terminal] [--fork] <session-id>  # 新しいターミナルウィンドウを開き <dir> で claude --resume を実行(既定 iterm2。--fork は分岐。アプリの Resume / Branch が呼ぶ。§4.6)
shiibar-cc conversations index [--json]           # 会話索引の更新(差分。初回は全構築。--json = 進捗の行 JSON。§4.6)
shiibar-cc conversations search [<query>] [--json] # 会話の検索(追いつき込み。クエリ無しは全件 = browse。§4.6)
shiibar-cc conversations show <session-id> [--json] # 会話全文の取得(§4.6)
shiibar-cc doctor             # 診断(下記)
```

- **selector**: target の完全一致、または `.`(カレントディレクトリと cwd が一致するエージェント。
  UUID の手打ちを不要にする)。cwd 部分一致などの拡張は実運用のシグナル待ち(§8.10)。
  複数一致は exit 1(該当なしの 2 と区別。理由は stderr)
- **focus の selector 解決**: 完全一致 target は destination そのものなので daemon を介さず、prefix で振り分けたターミナルモジュール(§4.3)へ直接渡す
  (daemon が落ちていても・entry が stale で消えていてもタブが生きていれば飛べる。「該当なし」はターミナル走査の失敗=exit 2)。
  daemon の list を引くのは `.`(cwd 一致)を解決するときだけ。focus 成功後の `seen` 送信は
  best-effort(失敗しても飛べた事実は覆さない)
- **exit code(全サブコマンド共通)**: 0 成功 / 1 接続・内部エラー(daemon 不在含む。stderr に理由) /
  2 該当なし(wait では対象消滅。理由は stderr に出す) /
  3 osascript 権限(TCC)エラー / 124 wait タイムアウト。
  **例外は `report` のみ**: hooks を阻害しないため、daemon 不在・タイムアウトを含め常に exit 0(§4.1)
- **wait の selector 解決**: 開始時に 1 回解決し、以降はその target を追う(未登録なら出現を待つ)。
  `--timeout` 省略時は無限に待つ
- **resume は daemon に接続しない**(ターミナルモジュール直呼び。§4.3 の `open_resume_window`)。
  引数は cwd と session_id の明示指定、`--terminal`(省略時 `iterm2`)、`--fork` である — 会話の知識
  (transcript)は持たない(それは conversations モジュール。§4.6)。**どのターミナルで開くかも
  自分では判断しない**: focus と違って飛び先のタブが存在せず target からも導けないため、
  判断材料(直近エントリの種別)を持つ呼び出し側 = アプリが決めて渡す(§4.6)。
  CLI を直接使うスクリプトには `--terminal` が明示手段になる。
  **`--fork` を付けると、ターミナルで実行するコマンドに `--fork-session` を追加する**
  (`claude --resume <session-id> --fork-session`。その会話のコピーから新しい session ID の会話が始まり、
  元の会話は変更されない — 測定結果は §7-6)。違いはこのフラグだけで、ウィンドウの開き方・cwd の確認・
  exit code は `--fork` なしと同じ。**cwd は絶対パス必須で、実行前に存在を確認する**(相対パス・
  不存在は AppleScript に触る前に exit 1 — transcript はフォルダより長生きするため)。
  exit code は 0 成功 / 1 内部エラー / 3 TCC(共通系統のうち 2 と 124 は使わない)
- **conversations 系も daemon に接続しない**(データ源は transcript と `~/.claude/sessions/` の
  pid ファイル。§4.6)。exit code: `index` / `search` は 0 成功(検索 0 件も成功)/ 1 内部エラー
  (索引構築不能・有効な検索語が無いクエリを含む — 黙って 0 件を返さない)。`show` は 0 / 1 / 2
  (session-id が索引に無い)。出力は既定が人間向けテキスト、`--json` で機械可読(doctor と同じ 2 面性)
- **conversations の出力 JSON(スクリプトが依存してよい公開契約)**。命名は NDJSON プロトコルと同じ
  snake_case、時刻は epoch 秒、消費者は未知フィールドを無視する(§4.2 と同じ前方互換):
  - `search`: `{"conversations":[{"session_id","cwd","title","updated_at","live","last_prompt"}]}` —
    新しい順。`title` は null 許容(フォールバックは表示側の責任 — §4.6)。`last_prompt` は、
    その会話で最後の人の発話の先頭 1 行・80 文字(80 文字は §9 の task と同値)で、人の発話が無ければ null
  - `show`: `{"session_id","cwd","title","messages":[{"seq","role"("user"|"assistant"),"text"}]}` —
    `text` は全文(切り詰めは表示側)
  - `index --json`: 行 JSON のストリーム — `{"event":"start","total":N,"full_build":B}` /
    `{"event":"progress","done":N,"total":N}`(間引きは §9)/ `{"event":"done","indexed":N,"removed":N}` /
    `{"event":"error","message":"…"}`(exit 1 と対)。**`start` は 1 ストリームに複数回現れ得て、
    カウンタは非単調**(構築者の交代 — §4.6 の中継)。消費者は常に最新の行を描く。
    `full_build` は、その構築が全構築(初回・スキーマ更新後・破損からの回復)のとき true、
    差分の更新のとき false である(中継された `start` も、構築者と同じ値を持つ)
- **conversations の排他と進捗**: 機構(flock・meta 表への進捗記録・ロック待ち中の中継)は
  §4.6「追いつき」「索引の更新」が正。CLI 契約として保証するのは「どの `index` を呼んでも
  同じ形の進捗ストリームが得られ、呼び出し側は子プロセスの管理を持たなくてよい」こと
- **doctor**: 以下を順に検査して人間向けに報告する —
  socket 疎通(`info` の応答)/ daemon の version・last_report_at / hooks プラグインの有無
  (`~/.claude/settings.json` の `enabledPlugins` に `shiibar-cc@shiibar-cc` が有効値で入っているか。§4.1)/
  `shiibar-cc` が PATH にあるか /
  osascript の TCC 権限(**起動中の対応ターミナルごとに**無害な走査を 1 回試す。未起動のターミナルは
  probe しない — 使っていないターミナルへの権限プロンプトを誘発しないため(§8.47)。スキップは
  人間向け出力に `[info]` で明示し、黙って省略しない)/
  Space 切り替え設定(NSGlobalDomain の `AppleSpacesSwitchOnActivate` が明示 `0` なら warn —
  OFF だと focus がウィンドウのある Space / ディスプレイに切り替われない。§7-1。
  未設定・`1`・読み取り失敗は ok 扱い — 既定が ON のため誤警告より見逃しを選ぶ)。
  「通知が来ない」「飛べない」の切り分けはまずこれを実行する。
  **`--json`** で同じ検査結果を `{"checks":[{"id","status"("ok"|"warn"|"fail"),"summary","hint"}]}` として
  出力する(アプリの Setup Check が読む。exit code の意味は人間向けと同じ。判定ロジックは CLI 側が正。
  人間向け出力だけにある `[info]`(ターミナル未起動で TCC 未検査)は JSON では `ok` に畳む — 失敗ではないため)

### 4.5 メニューバーアプリ(`app/`)

SwiftUI(macOS 14+(§8.34))。メニューバーの**トレイアイコン**(全セッションの状態の
ロールアップ 1 つ。常時表示)と、2 つの画面で構成する: アイコンのクリックで開く**ポップオーバー**と、
ポップオーバーから開く**ウィンドウ**である。ポップオーバーとウィンドウは同じ内容(実行中のセッションと過去の会話の一覧、および
会話の全文を表示する会話ペイン)を表示し、レイアウトは 1 種類である(§8.49)。通知クリックで focus。

- **見た目の正**: トレイアイコンは `docs/menubar-design.html`、ポップオーバーとウィンドウは
  `docs/window-design.html`。
  トレイ = フルハイトの角丸窓 + 左上スロットの **1 グリフ** + working のときだけ下段の **3 つの点**、
  の**テンプレートアイコン**(「Claude が居る窓」)。スロットのグリフと 3 つの点の有無で、
  ロールアップを表す: waiting = **太い `!`**(紋章と入れ替え — あなたへの要求が窓に立つ)>
  working = **`✻` の下に 3 つの点** > idle = **`✻` だけ**(素の U+273B)。
  減光 2 段階: idle 0.8 / エージェントなし・切断 0.45。unreviewed が 1 台でもいれば枠の角に赤バッジ。
  描画は NSImage 合成で、状態が変化したときに再描画する。**トレイアイコンはどの状態も静止画で、
  アニメーションのタイマーを使用しない**。画像を設定するたびに、AppKit がメニューバーの表示を
  メインスレッドで作成し直し、その処理時間は画像の内容に関係なく一定である。そのため、画像を
  周期的に変更すると、working のセッションがある間、CPU を使用し続ける(§8.51)。
  **画像を設定するのは、表示する内容(グリフ・3 つの点の有無・減光・赤バッジと、メニューバーが
  暗いかどうか)が前回の設定から変化したときだけである**。内容が同じ画像を毎回設定すると、
  処理が終了しない。画像を設定すると、AppKit がメニューバーの表示を更新し、その更新がボタンの外観を
  変更する。外観の変更は、外観の監視(赤バッジ付きの画像はテンプレート画像ではないので、外観に
  合わせた再描画に必要)を起動し、監視が画像をもう一度設定する。本節は挙動のみを規定する
- **daemon 接続**: `NWConnection` で UDS に接続し、subscribe の行 JSON を `JSONDecoder` でデコードする。
  切断時(daemon 再起動・スリープ復帰)は 1 秒から倍々・上限 30 秒のバックオフで再接続(snapshot で状態回復)。
  未知の event / status は無視する(前方互換)
- **トレイアイコンのクリック**: ウィンドウを開いていない間は、ポップオーバーを開閉する。
  ウィンドウを開いている間は、ウィンドウを前面に移して key にし、ポップオーバーは表示しない
  (別の Space にあるウィンドウは現在の Space へ移動する。Space は切り替えない)。
  アイコンはクリックを自分で受け取る(メニューやパネルを OS に開かせる形式にしない)
- **グローバルホットキー**(§8.50): 利用者が Settings で登録したキーの組み合わせ(下記「Settings ウィンドウ」)を、
  他のアプリが前面にある間も受け取る。初期状態は未登録であり、未登録の間は何も受け取らない。
  登録にはシステムのホットキーの API(Carbon の `RegisterEventHotKey`)を使用する
  (アクセシビリティの権限を要求しない。登録した組み合わせは、前面のアプリに届かなくなる)。
  ホットキーを押したときの動作は、トレイアイコンのクリックと同じ分岐である。
  - ウィンドウを開いていない間: ポップオーバーを開閉する(閉じている場合は開き、開いている場合は閉じる)
  - ウィンドウを開いている間: ウィンドウを前面に移して key にする(トレイアイコンのクリックと同じ)。
    ウィンドウが既に key の場合も、閉じない

  **ホットキーで開いたとき(または前面に移したとき)は、検索欄ではなく一覧にフォーカスを移す**。
  下記「キー操作」の検索欄の Enter と同じく、選択なしの場合は先頭の行を選択する
  (行が 1 つも無い場合は、検索欄にフォーカスを移す)。
  詳細ページを表示している場合は、ページを変更せず、会話ペインにフォーカスを移す。
  Settings ウィンドウでキーの組み合わせを記録している間は、ホットキーの登録を一時的に解除する
- **ポップオーバー**: OS 標準のポップオーバー(`NSPopover`。矢印あり)を、アイコンの直下に表示する。
  ポップオーバーの外観(ライト / ダーク)は、アプリの外観(Settings の Appearance。System の場合は OS の設定)に
  従う(開くたびに、アプリの外観をポップオーバーに設定する。`NSPopover` は、外観を設定しない場合、
  アプリの外観に従わない)。ポップオーバーを表示している間の外観の変更は、次に開いたときに反映する。
  幅は、文字の大きさに連動する(下記「文字の大きさ」。ドラッグでは変更できない)。高さは、ポップオーバーの下端をドラッグして変更できる(上端はアイコンの直下から
  移動せず、下端だけが移動する)。変更した高さは、ドラッグを終了した時点で UserDefaults に記憶し、次も同じ高さで開く。
  ドラッグ中に高さが初回の高さの近くになると、初回の高さに固定する(固定する範囲は §9。
  範囲を超えてドラッグを続けると、再びカーソルに追従する)。固定する範囲に入るたびに、トラックパッドの
  触覚フィードバック(`NSHapticFeedbackManager` の `.alignment`)を 1 回発生させる。
  下端のドラッグ領域(§9)は、その位置にある他の表示よりも先にマウスの操作を受け取る。
  初回の高さ・最小の高さ・最大の高さは §9。開いたときに `NSApp.activate` を実行して key にする。
  一覧のページを表示しているときは、検索欄にフォーカスを移す(検索欄に文字があるときは、全選択せず、
  カーソルを文字の末尾に配置する)。詳細ページを表示しているときは、会話ペインにフォーカスを移す。
  **閉じる契機**: アイコンのクリック / ポップオーバーの外のクリック / 他のアプリへの切り替え /
  Esc / ⌘W / `Open in window` / ⌄ メニューの About・Settings…・Setup Check… / Jump・Resume・Branch の成功。
  Jump・Resume・Branch が失敗したときは閉じず、メッセージ行または警告行にエラーを表示する
  (Jump の該当なし — exit 2 — のときも閉じないが、エラーは表示しない。下記「実行のボタン」)。
  ポップオーバーだけを表示している間、アプリは accessory のままである。この間も、Edit メニューの
  標準ショートカット(⌘C / ⌘V / ⌘X / ⌘A / ⌘Z)と、アプリメニューのショートカット(⌘, / ⌘R / ⌘W / ⌘Q)は
  動作する
- **ウィンドウ**: ポップオーバーの見出し行の `Open in window` で開く(ポップオーバーは閉じる)。
  位置と大きさを記憶し、次も同じ位置と大きさで開く。初回は §9 の大きさで、ディスプレイの中央に開く。
  閉じる操作は赤ボタンと ⌘W である。Esc では閉じない。Jump / Resume / Branch を実行しても閉じない
  (ターミナルが前面に移り、ウィンドウはその後ろに残る。ピンが ON なら手前に残る)。
  全 Space に追従しない。他の場所をクリックしても閉じない
- **ポップオーバーとウィンドウは 1 つの状態を共有する**: 検索欄の文字・行の選択・表示中のページ
  (一覧のページまたは詳細ページ。下記「幅による切り替え」)・一覧のスクロール位置・
  会話ごとのスクロール位置は、
  アプリを終了するまで保持する。ポップオーバーを閉じて再度開いたとき、`Open in window` で
  ウィンドウに移ったとき、ウィンドウを閉じた後にポップオーバーを開いたときのいずれも、
  同じ状態から操作を続けられる
- **ウィンドウを開いている間だけ、アプリは通常アプリになる**(§8.30): 開くと Dock と ⌘Tab に載り、
  画面上端にアプリメニューが表示される。閉じると accessory(常駐)に戻り、どちらも消える。
  Dock アイコンのクリック・⌘Tab での切り替えはウィンドウを前面に移す。
  ポップオーバー / Settings / Setup Check を単独で開いても切り替えは起きない
- **見出し行**: ポップオーバーとウィンドウの上端は見出し行 1 行である。ポップオーバーは左から
  **検索欄 / ⟳ / `Open in window` / ⌄**、ウィンドウは **検索欄 / ⟳ / ピン / ⌄** を並べる
  (ウィンドウでは `Open in window` の位置がピンに替わる。検索欄と ⟳ の挙動は §4.6)。
  ツールチップは `Refresh` / `Open in window` / `Keep on top`。
  ウィンドウのタイトルバーは非表示(タイトルを表示せず、タイトルバーを透明にする)で、見出し行は信号機ボタンと同じ高さに
  配置する。見出し行の空いている部分でウィンドウをドラッグできる。ウィンドウの `title` は
  **Shiibar CC**(Mission Control 等の一覧表示と、実装のタイトルフィルタが使用する — 画面には描かれない)
- **幅による切り替え**(§8.49): レイアウトは 1 種類で、表示する幅によって列の数だけが変化する。
  - **1 列**(幅が §9 のしきい値より狭いとき。ポップオーバーは常に 1 列): **一覧のページ**と
    **詳細ページ**のどちらか一方を表示する。一覧のページは、見出し行・一覧・固定フッターで構成する。
    詳細ページは、選択中の会話の会話ペイン(§4.6)だけで構成し、見出し行は表示しない
    (検索欄・⟳・ピン・⌄ は、一覧のページに戻って操作する。ウィンドウの詳細ページでは、
    会話ペインのヘッダの左端に信号機ボタンを配置し、ヘッダの空いている部分でウィンドウをドラッグできる)。
    ページの切り替えはスライドで、詳細ページは右から表示され、一覧に戻るときは右へ退く(時間は §9)
  - **2 列**(幅がしきい値以上のとき): 左の列に一覧、右の列に選択中の会話の会話ペインを表示する。
    左の列(一覧の列)の幅(§9)は、ウィンドウの幅を変更しても変化せず、右の列だけが伸縮する
    (右の列の最小の幅を確保できない場合と、文字の大きさとの関係は、次の「列の境界のドラッグ」)
  - **列の境界のドラッグ**(§8.53): 2 列のとき、列の境界を左右にドラッグして、一覧の列の幅を変更できる。
    境界の上では、カーソルを左右リサイズの形にする。ドラッグ領域(§9)は、その位置にある他の表示よりも先に
    マウスの操作を受け取る。ドラッグ中は、アニメーションなしで幅を追従させる。
    幅は、ドラッグを開始した時点の幅に移動量を加えて、範囲に収めた値である(範囲の端を超えた後に戻すと、
    境界がポインタの位置に追従する)。**幅の範囲**は、一覧の列の最小の幅(§9)から、ウィンドウの幅から
    右の列の最小の幅(§9)を引いた幅までである(その時点のウィンドウの幅で計算する。2 列になる幅ちょうどの
    ウィンドウでは、既定の幅より広げることができない。範囲の上限が最小の幅より小さい場合は、最小の幅にする)。
    **幅の記憶**: ドラッグを終了した時点の幅(小数点以下は四捨五入)が、開始した時点の幅(同じく四捨五入)と
    違う場合に、その幅を UserDefaults に記憶する。移動のないクリックでは記憶しない。ドラッグ中に 1 列になった場合
    (文字の大きさの変更など)と、ウィンドウを閉じた場合は、ドラッグを終了し、記憶しない。
    **境界をダブルクリックすると、記憶した幅を消去して、既定の幅に戻す**(アニメーションなし。
    記憶した幅が無い場合は、何もしない)。
    **記憶した幅がある間**は、文字の大きさを変更しても、一覧の列の幅を変更しない(記憶した幅が無い間は、
    既定の幅を使用し、文字の大きさに連動する — 下記「文字の大きさ」)。表示する幅は、記憶した幅を
    上記の範囲に収めた値である(記憶した値は変更しない。ウィンドウを狭めると、右の列に最小の幅を残して
    一覧の列が狭くなり、広げると、記憶した幅に戻る)。保存済みの値が数値でない場合と、0 以下の場合は、
    記憶した幅が無いものとして扱う。
    2 列になる幅は、記憶した幅に関係なく、既定の幅から計算する(§9)
  - **幅を変更したとき**: 詳細ページを表示したまま 2 列の幅まで広げると、同じ会話を選択した 2 列になる。
    2 列から 1 列の幅まで狭めると、一覧のページを表示する(選択は保持する)
- **ウィンドウのサイズ**: 縦横にリサイズできる。初回の大きさと最小の大きさは §9。
  一覧は高さいっぱいに広がり、収まらない分はスクロールする。行数の増減でウィンドウの高さは変更しない
  (常駐する器の大きさは人が決める。§8.32)
- **一覧は 2 つの区画**(§8.49): 上が **Running**(daemon が追跡している実行中のセッション)、
  下が **History**(それ以外の会話。§4.6)。区画の見出しは太字の区画名と行数。
  **行が 1 つも無い区画は見出しごと表示しない**。Running の行の状態は、行頭の記号が示す。
  **行は 1 枚ずつのカード**で、どちらの区画も 3 行の文字を表示する
- **Running の行**: daemon の一覧(subscribe)がそのまま行になる。
  **1 行目**は、waiting の間は `message`(許可内容 / `waitingFor`)、それ以外は会話のタイトル
  (History の行と同じタイトル。`session_id` が一致する search の結果から取得する — §4.6)である。
  タイトルを取得できない間は `task`(最後の依頼文)、それも無ければラベルを表示する(§3.6)。
  **2 行目 = ラベル + 経過時間**。**3 行目 = 最後に自分が送った発話**(`task`。先頭に `❯` を付ける。`task` に含まれる改行は
  空白に置き換えて、1 行で表示する。
  `task` が無ければ空行にして、行の高さをそろえる)。
  行頭の状態記号: **薄い `✻`(静止)= idle / 輪郭の吹き出し + 太い `!` = waiting /
  グリフ循環スピナー = working**(Claude Code の TUI と同じ `·✢✳✶✻✽` の循環・
  コサインイージング周期 2 秒。「瞬いている Claude」と「静止している Claude」の対。
  ポップオーバーまたはウィンドウを表示している間だけ動作させる)。
  **未確認 = 1 行目太字 + 状態記号の右肩の赤バッジ**(トレイの「窓の右肩バッジ」と同じ文法)。
  **並びは新しいセッション順**(`created_at` の降順)。キーが不変なので、状態が変化しても行は移動しない。
  unreviewed を位置では示さない(§8.31)。`agent_removed` で行を消す
- **実行のボタン**(§8.49): Jump / Resume / Branch は、**下部パネル**(§4.6)にラベル付きのボタンで
  表示する。対象は選択中の行である。行の中には、実行のボタンを配置しない。
  主ボタンは **Jump**(Running の行)または **Resume**(History の行)、副ボタンは **Branch** である。
  下部パネルは、1 列の一覧のページと詳細ページ、2 列の右の列の下端に表示するので、
  画面に表示する実行のボタンは常に 1 組である。行を選択していない間は、ボタンを表示しない。
  ポップオーバーは、実行が成功すると閉じる(上記「ポップオーバー」)。
  - **Jump**: `shiibar-cc focus <target>` を subprocess 実行する(成功時に seen が送られ、未確認が消える)。
    該当なし(exit 2)のときは、エラーを表示しない(ポップオーバーも閉じない) — Running の行は
    subscribe でライブに再生成され、消えたタブの行は reconcile で一覧から除かれる
  - **Resume** / **Branch**: §4.6。Branch は Running の行でも History の行でも押せる
    (実行中の会話の分岐は、その時点までに記録された会話のコピーから始まる — §7-6)。
    Running の行で `session_id` か `cwd` が空のときは Branch を disabled にする
- **行の `>` ボタン**(§8.49): 1 列では、どの行も右端に `>` のアイコンボタンを常に表示する
  (ツールチップは `Open`)。押すと、その行を選択して詳細ページを開く。
  2 列では表示しない(選択中の会話は、右の列に表示している)
- **行の選択**(§8.49): 選択している行は 0 行または 1 行である。選択中の行は、
  **キーの操作対象が一覧である間**は淡い青の地と淡い青の枠で、それ以外の間は淡い灰色の地と灰色の枠で示す。
  キーの操作対象が一覧である間とは、その画面(ポップオーバーまたはウィンドウ)が key で、かつ一覧に
  フォーカスがある間(下記「キー操作」)である。検索欄にフォーカスがある間と、ウィンドウが key でない間
  (他のアプリを操作している間など)は、灰色で示す。
  行を選択するのは、利用者の操作(行のクリック・行の `>` ボタン・↑ / ↓・選択なしの間の検索欄の Enter・
  詳細ページでの前後の会話への切り替え)だけである。アプリの起動後は、
  利用者が行を選択するまで、どの行も選択していない。検索文字列を変更しても、選択中の行が
  検索結果に含まれている間は、選択を変更しない。
  選択中の行が一覧から無くなったとき(検索文字列の変更・再取得・セッションの終了)は、
  選択なしにする(他の行を選択しない)。1 列の詳細ページで表示中の会話が一覧から無くなったときは、
  一覧のページに戻って、選択なしにする。
  選択は、Running の行では target、History の行では `session_id` で保持する。
  Running の行が終了して History に移ったときは、`session_id` が同じ行の選択を保持する。
  History の行の会話が Running に移ったとき(Resume の後など)も、`session_id` が同じ行の選択と、
  表示中のページを保持する。
  選択中の Running の行が消えた時点では、その契機による History の再取得(§4.6)が完了するまで
  選択と詳細ページを変更せず、再取得の結果に同じ `session_id` の行が無いとき(再取得がエラー終了した
  ときを含む)だけ、選択なしにする。再取得が完了するまでの間は、下部パネルのボタンを disabled にし、
  詳細ページのヘッダの位置(`2 / 4`)を表示しない。
  **選択なしの間**は、1 列では詳細ページを開かない。2 列の右の列は、会話ペインのヘッダも下部パネルも
  表示せず、中央に `No conversation selected` の 1 行だけを表示する。
  **選択した行が一覧の表示範囲の外にあるとき**(↑ / ↓ での移動、選択なしの間の検索欄の Enter と
  グローバルホットキーによる先頭の行の選択、詳細ページから一覧のページへ戻ったとき)は、その行の全体が表示範囲に収まる最小の量だけ、一覧をスクロールする。
  同じ操作で一覧の先頭の行を選択したときは、行が表示範囲の中にあっても、一覧を最上部までスクロールする
  (先頭の行の上にある区画の見出しも表示する)
- **行のクリック**: `>` ボタンとスター(§4.6)以外の部分をクリックすると、その行を選択する。
  **青で表示している選択中の行をクリックすると、選択を解除する**(選択なしになる)。
  灰色で表示している選択中の行(上記「行の選択」)をクリックしたときは、選択を解除せず、一覧にフォーカスを移す。
  青か灰色かは、マウスのボタンを押した時点の表示で判定する。
  key でないウィンドウの行をクリックしたときは、どの行でも、ウィンドウを key にする。
  クリックでは詳細ページを開かない(1 列で詳細ページを開く操作は、`>` ボタンと → である)。
  2 列では、右の列が選択した会話を表示する。
  どちらの区画の行にも、ホバーで枠の色を変更する表示を付ける。
  Running の行は `session_id` で会話を特定する。`session_id` が空の行も、他の行と同じように選択でき、
  詳細ページを開ける。この行の会話ペインは、ヘッダに行の 1 行目の文字とホーム相対の cwd を表示し、
  メッセージ面の中央に `No conversation to show` の 1 行だけを表示する(下部パネルは通常どおり表示する。
  Branch は disabled — 上記「実行のボタン」)
- **行のダブルクリック**: `>` ボタンとスター以外の部分をダブルクリックすると、その行を選択し、一覧にフォーカスを移して、
  Jump(Running の行)または Resume(History の行)を実行する。一覧にフォーカスがある間の Enter と同じ動作であり、
  対応するボタンが disabled のときは、選択とフォーカスの移動だけを実行する。
  行の状態(未選択・青の選択中・灰色の選択中)による違いは無い。
  **ダブルクリックは、クリックとは別の操作である**: ダブルクリックでは、上記「行のクリック」の動作
  (青で表示している選択中の行の選択の解除)を実行しない。
  そのため、青で表示している選択中の行のクリックによる選択の解除は、ダブルクリックでないことが確定した時点
  (マウスのボタンを押してから、システムのダブルクリックの間隔が経過した時点)で実行する。
  未選択の行の選択と、灰色の行へのフォーカスの移動は、ダブルクリックの結果と一致するので、
  遅らせない。
  待っている間に、選択中の行または表示中のページが変化したとき(↑ / ↓、別の行のクリック、`>` ボタン、→、
  行が一覧から消えたとき)と、ポップオーバーまたはウィンドウを閉じたときは、選択の解除を取り消す。
  3 回以上の連続したクリックは、3 回目以降で、行の選択と一覧へのフォーカスの移動だけを実行する
  (Jump / Resume を再実行せず、選択も解除しない)
- **キー操作**(§8.49): ポップオーバーとウィンドウは、次のキーを、フォーカスのあるビューより先に処理する。
  キーの動作は、**検索欄にフォーカスがあるかどうか**で 2 通りに分かれる。検索欄では文字の編集だけを行い、
  行の操作は一覧で行う。「一覧にフォーカスがある」は、検索欄にフォーカスが無い状態を指す
  (詳細ページと、会話ペインにフォーカスがある場合を含む)。
  検索欄にフォーカスがある間は、検索欄にカーソルを表示する。一覧にフォーカスがある間は、カーソルを表示しない。

  | キー | 検索欄にフォーカスがある間 | 一覧にフォーカスがある間 |
  |---|---|---|
  | 文字の入力 / Delete | 検索欄に入力する(標準の動作) | 何もしない |
  | ← / → | 検索欄のカーソルを移動する(標準の動作) | → は、1 列の一覧のページで、選択中の行の詳細ページを開く(選択なしの間は何もしない)。← は、1 列の詳細ページで一覧のページに戻る。それ以外では何もしない |
  | ↑ / ↓ | 何もしない | 前後の行に選択を移動する(端では移動しない)。選択なしの間は、どちらのキーも一覧の先頭の行を選択する。検索中は検索結果の行だけを移動する。1 列の詳細ページでは、会話をスクロールする(会話ペインの標準の動作。Space と Page Up / Page Down も同じ) |
  | ⌥↑ / ⌥↓ | 検索欄のカーソルを移動する(標準の動作) | 1 列の詳細ページで、表示する会話を前後の行の会話に切り替える(選択も移動する。スライドはしない。端では何もしない)。それ以外では何もしない |
  | Enter | 一覧にフォーカスを移す。選択なしの間は、一覧の先頭の行を選択する。行が 1 つも無いときは何もしない | 選択中の行の Jump または Resume を実行する(下部パネルの主ボタンと同じ)。どのページでも同じ |
  | ⌘Enter | 何もしない | 選択中の行の Branch を実行する(下部パネルの Branch と同じ)。どのページでも同じ |
  | ⌘G / ⇧⌘G | 会話内の次のヒット / 前のヒットに移動する(§4.6「ヒットナビゲーション」)。会話ペインを表示している間だけ有効 | 同じ |
  | ⌘F | 何もしない | 検索欄にフォーカスを移す。1 列の詳細ページでは、一覧のページに戻ってから移す |
  | ⌘= / ⌘+ / ⌘− / ⌘0 | 文字の大きさを変更する(下記「文字の大きさ」)。どのページでも同じ | 同じ |
  | Esc | ポップオーバーを閉じる。ウィンドウでは何もしない | 同じ。どのページでも同じ |

  **一覧にフォーカスを移す操作**は、検索欄での Enter、行のクリック、行の `>` ボタンである。
  **検索欄にフォーカスを移す操作**は、検索欄のクリック(消去のボタンを含む)と ⌘F である。
  ポップオーバーを開いたときのフォーカスは、上記「ポップオーバー」のとおりである。
  Tab は標準のフォーカスの移動である。選択なしの間と、対応するボタンが disabled のとき、
  一覧にフォーカスがある間の Enter と ⌘Enter は何もしない。
  **日本語入力の変換が未確定(marked text)の間は、すべてのキーを日本語入力に渡す**
  (変換の確定の Enter と、候補の選択の ↑ / ↓ を横取りしない)
- **クリックスルー**: ウィンドウにフォーカスが無い状態でも、行・`>` ボタン・下部パネルのボタンは
  1 クリック目で反応する(状態を確認してすぐ Jump するための画面なので、前面化のためだけのクリックを要求しない)
- **ピン(Keep on Top)**: ウィンドウの見出し行のピンのボタン。ON はアクセントカラーの塗り、OFF は輪郭だけ。
  既定は OFF。ON の間だけウィンドウを最前面(floating レベル)に保つ。**変更するのはウィンドウレベルだけ** —
  全 Space への追従はしない、フォーカスも奪わない(クリックスルーと組み合わせると、最前面の一覧を
  確認しながらターミナルで作業し、そのまま Jump できる)。値は UserDefaults に永続し、
  押した直後に反映する(§8.33 / §8.49)。ポップオーバーにピンは無い
- **⌄ メニュー**(見出し行の右端): **About Shiibar CC**(標準の About パネル =
  `orderFrontStandardAboutPanel`。アイコン・名前・バージョンは bundle から自動)/ セパレーター /
  **Settings…**(下記・§8.26)/ **Setup Check…** / セパレーター /
  **Rescan**(= `shiibar-cc reconcile`。手動リロード)/
  **Clear badges**(全セッションの unreviewed フラグを消す。未読が 1 つも無ければ disabled。
  通知センターの配信済み通知は**変更しない**(§8.24 — 通知は利用者が自分で消す)。
  実装は未読 target ごとに `shiibar-cc seen <target>` を呼ぶ)/ セパレーター / **Quit**。
  UI 文言は英語
- **メニューバーのメニューはアプリメニューと Edit メニューの 2 個**(File / Format / View / Window / Help は
  表示しない)。Edit は標準項目のみ(Undo ⌘Z / Redo ⇧⌘Z / 区切り / Cut ⌘X / Copy ⌘C /
  Paste ⌘V / Select All ⌘A) — テキスト欄(検索欄・Settings)や会話ペインで標準ショートカットを
  配達するために必要(メニュー項目が無い ⌘V 等は macOS では配達されない。§8.41)。
  システムが Edit に注入する項目のうち **Start Dictation / Emoji & Symbols は標準の抑止設定で
  表示しない**。**Delete / AutoFill は受け入れる**(SwiftUI がメニューを所有し、開くたびに再生成する
  ため、公認の手段では消せない — §8.42)。
  アプリメニューの構成:
  About Shiibar CC / セパレーター / Settings…(⌘,)/ Setup Check… / セパレーター /
  Rescan(⌘R)/ Clear badges(未読ゼロで disabled)/ セパレーター /
  Close Window(⌘W。key ウィンドウを閉じる標準動作。ポップオーバーが key の間は、ポップオーバーを閉じる。
  **閉じられるウィンドウが無ければ disabled**)/
  セパレーター / Quit Shiibar CC(⌘Q)。
  Close Window を除き、各項目の挙動は ⌄ メニューの同名項目と同一。
  メニューの Quit は ⌄ の Quit と同じ終了処理(daemon の shutdown ack を待つ処理)を通す
- **固定フッター**: 一覧の下(スクロールに含めない位置)に、上から警告行(下記「異常の可視化」)、
  **メッセージ行**、**キーの案内**を配置する。1 列では、キーの案内の段が下部パネル(§4.6)になる。
  - **メッセージ行**: 表示する内容があるときだけ表示する 1 行である。索引の進捗・エラー・
    ⟳ の一時表示(§4.6)と、Rescan の一時表示(Rescanning… / ✓ Rescan done / Rescan failed。
    表示時間は §9)を表示する
  - **キーの案内**: 常に表示する 1 行で、その時点で使用できる移動のキーを示す(上記「キー操作」)。
    **検索欄にフォーカスがある間**は、1 列でも 2 列でも `↩ List` だけを表示する。
    **一覧にフォーカスがある間**は、1 列の一覧のページは `↑↓ Move` / `→ Open`(`→ Open` は行を選択している間だけ)、
    2 列は `↑↓ Move` を表示する。
    実行のキー(Enter と ⌘Enter)は、下部パネルのボタンの中に表示する(§4.6)。
    1 列では、キーの案内を下部パネルの左側に配置する(一覧のページと詳細ページの両方。§4.6)。
    2 列では、左の列のフッターにキーの案内だけを表示する(実行のボタンは右の列の下部パネルにある)
  - **1 列の詳細ページ**では、警告行とメッセージ行を、会話ペインの下部パネルのすぐ上に表示する
    (詳細ページを表示している間に発生した切断や TCC エラーを、一覧に戻らなくても確認できるようにする)
- **表示中の更新**: スピナーは、ポップオーバーまたはウィンドウを表示している間だけ動作させる。
  経過時間の基準は、表示した時点で再取得したうえで、**表示中は毎分再取得する**(表示が分粒度なので
  毎秒の更新は不要)。タイマーも、表示している間だけ動作させる。通知許可の denied 判定も、
  ポップオーバーまたはウィンドウを表示するたびに再評価する
- **Settings ウィンドウ**(⌄ → Settings…): 設定をまとめる独立ウィンドウ。Setup Check と同じく
  表示時に `NSApp.activate`。**閉じるボタンは置かない**(全項目が、選んだ時点または入力を確定した時点で反映され、
  「OK で確定」が無いため。閉じるのはタイトルバーの赤ボタンと ⌘W。§8.26)。
  値はすべて UserDefaults に永続。UI 文言は英語。**見た目は SwiftUI の `Form` +
  `.formStyle(.grouped)`**(System Settings と同じグループドフォーム — トグルスイッチ・
  囲みカード・行区切りは OS が描く。素の VStack + Toggle + Divider にはしない)。構成は 2 グループ
  (General と Sounds)で、General は Start at Login / Appearance / Text size / Global shortcut の順である:
  - **General**: Start at Login(トグル。`SMAppService` の状態を直接読み書きする)/
    **Appearance**(ポップアップ: System / Light / Dark。既定 System = OS に従う。
    アプリ全体の外観(`NSApp.appearance`)を選んだ瞬間に切り替え、UserDefaults 永続・起動時に再適用。
    ポップオーバー・ウィンドウ・Settings・Setup Check が一括で従う。
    トレイアイコンはテンプレート画像なのでメニューバー側の外観に従い続ける。§8.30)/
    **Global shortcut**(キーの組み合わせを記録する欄。上記「グローバルホットキー」のキーを登録する。
    未登録の間は `Record Shortcut` を表示する。欄をクリックすると記録中になり、`Type shortcut` を表示する。
    記録中に押したキーの組み合わせを、その時点で登録して UserDefaults に保存し、記録を終了する。
    登録済みの間は、組み合わせを修飾キーの記号とキーの名前で表示し(例: `⌃⌥Space`、`⇧⌘K`)、
    右端に登録を解除する × ボタンを表示する。
    **修飾キーは ⌃ / ⌥ / ⇧ / ⌘ の任意の組み合わせを登録できる**。ただし、⌃ / ⌥ / ⌘ のいずれかを含まない
    組み合わせ(修飾キーなし、または ⇧ だけ)は、ファンクションキー(F1〜F20)の場合だけ登録できる
    (文字の入力に使用するキーを、すべてのアプリで入力できなくなるため)。
    登録できない組み合わせを押したときは、記録中のまま、欄の下に
    `Add ⌃, ⌥, or ⌘ to the shortcut` を表示する。
    システムが登録を拒否したときは、記録を終了して以前の登録を保持し、
    欄の下に `This shortcut is already in use` を表示する
    (他のアプリが同じ組み合わせを登録している場合、システムは登録を拒否しない。
    その場合にどちらのアプリが受け取るかは、システムが決める)。
    欄の下の案内は、次に記録を開始したとき、登録に成功したとき、記録を中止したときに消去する。
    記録中の Esc(修飾キーの有無に関係しない)、欄の外のクリック、Settings ウィンドウが key でなくなったときは、
    記録を中止して以前の登録を保持する。記録中は × ボタンを表示しない。
    キーの名前は、記録した時点のキーボード配列での文字を保存して表示する。
    文字を持たないキーは、`Space`、`F1`〜`F20`、メニューで使用する記号(↩ ⇥ ⌫ ⌦ と矢印など)で表示する。
    起動時の登録に失敗した場合は、保存した値を保持したまま、欄に `Record Shortcut` を表示する)
  - **General** の **Text size**: 数値の入力欄(幅 56pt・右寄せ)と、macOS 標準の
    ステッパー(1 ずつ変更)。説明は `Text in the popover and the window`。値と適用する範囲は、
    下記「文字の大きさ」。入力欄の値は、Enter を押したときと、入力欄を編集した後にフォーカスが外れたときに
    適用する(編集していない場合は、フォーカスが外れても適用しない。入力の途中で Settings ウィンドウを
    閉じた場合も、適用しない)。入力は、前後の空白を除いた、
    半角の数字だけの整数として解釈する(符号は受け付けない)。整数として解釈できないとき(空の入力を含む)は
    `Enter a whole number`、9〜18 の外の値のときは `Enter a number from 9 to 18` を説明の下に表示し、
    入力欄を現在の値に戻す。エラーの表示は、値を適用したとき(入力欄での有効な値の確定、ステッパー、
    ポップオーバーとウィンドウのキー。入力欄での現在と同じ値の確定を含む)に消去する。ステッパーとキーは、
    値が変化しない場合、エラーも消去しない。入力欄を編集している途中に、ステッパーまたはキーで値が
    変化した場合は、編集中の文字を破棄して、新しい値を表示する。ステッパーは、範囲の端では
    何もしない。ポップオーバーとウィンドウの ⌘= / ⌘− / ⌘0 で変更した値も、入力欄に反映する
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
- **文字の大きさ**(§8.52): Settings の Text size は、本文の文字の大きさ(pt)の整数で、範囲は 9〜18、
  既定は 13 である(§9)。ポップオーバーとウィンドウの全体(一覧、見出し行、下部パネル、会話ペイン)に
  適用する。固定フッター(警告行、メッセージ行、キーの案内)と、会話ペインのヘッダ・検索バー行を含む。
  トレイアイコン、Settings ウィンドウ、Setup Check ウィンドウ、メニュー、ツールチップには適用しない。
  `docs/window-design.html` の寸法は、文字の大きさが 13 のときの値である。
  - **13 に対する比率で連動する寸法**: すべての文字の大きさ(ボタンの中のキーの記号を含む)、行の高さ、
    上下の余白と上下の間隔、アイコンと記号とその枠(行頭の状態記号と赤バッジ、スター、虫眼鏡、
    消去のボタン、行の `>` ボタン、前後の会話に切り替えるボタン。アイコンの線の太さを含む)、
    検索欄の高さ、主ボタンの最小の幅
    (左右の寸法であるが、ラベルの文字に合わせて連動する)。比率を掛けた値は丸めない
    (丸めるのは、下記のポップオーバーの幅と一覧の列の既定の幅だけである)。
  - **固定の寸法**: 左右の余白と左右の間隔、角の半径、枠線の太さ、見出し行のボタンと会話ペインのヘッダの戻るボタン(どちらも 24pt)とそのアイコン、
    会話ペインのミニマップの幅と、その手前の折り返しの余白、ポップオーバーの下端のドラッグ領域、
    OS が描画する部品(ウィンドウの信号機ボタン、検索バー行の ‹ › のセグメント)。
  - **見出し行の高さ**は、ポップオーバーでは、検索欄の高さと見出し行のボタンの高さ(24pt)の大きいほうに、上下の余白(連動)を
    加えた値である。検索欄とボタンは、上下の中心をそろえる。
    ウィンドウの 2 列の右の列のヘッダは、上下の中心の位置(上端から 27pt)を固定にする
    (文字の大きさ 13 のときの上下の位置を保持するため。ヘッダの上の余白は、文字の大きさで変化する)。
  - **幅が不足する場合**: 下部パネルは、ボタンを優先して表示する。キーの案内は、残りの幅に全体が
    収まる項目だけを、先頭から表示する(項目の途中で切らない)。行の文字は、末尾を省略して 1 行で表示する(文字の大きさ 13 のときと同じ規則)。
  - **ポップオーバーの幅**は、比率で連動する(13 のとき 420pt。小数点以下は四捨五入する)。
    表示している間に文字の大きさを変更した場合も、その時点で幅を変更する。高さ(記憶した高さ、
    初回の高さ、最小の高さ、初回の高さに固定する範囲)は、文字の大きさで変更しない。
  - **ウィンドウ**は、記憶した大きさと最小の大きさを変更せず、内容だけを連動させる。
    2 列のときの一覧の列の既定の幅は、ポップオーバーの幅と同じ値で連動する(列の境界のドラッグで
    記憶した幅がある間は、記憶した幅を使用する — 上記「幅による切り替え」)。2 列になる幅は、
    一覧の列の既定の幅に 460pt を加えた値である(13 のとき 880pt)。文字の大きさの変更によって列の数が
    変化した場合は、上記「幅による切り替え」の「幅を変更したとき」と同じ規則を適用する。
    ウィンドウの見出し行と、1 列の詳細ページのヘッダは、行の高さが変化しても、上下の中心を
    信号機ボタンの中心にそろえる(上の余白は、文字の大きさで変化する)。
  - **スクロール位置**: 文字の大きさを変更したとき、一覧は、表示範囲の先頭にあった行を先頭に表示する。
    会話ペインは、スクロール位置を調整しない。
  - **キー**: ポップオーバーとウィンドウでは、⌘= で 1 大きく(⌘+ も同じ)、⌘− で 1 小さくし、
    ⌘0 で 13 に戻す(上記「キー操作」)。キーは、押した位置ではなく、入力される文字(`=` `+` `-` `0`)で
    判定する。18 での ⌘=、9 での ⌘−、13 での ⌘0 は値を変更しない(キーは処理済みとして扱い、
    フォーカスのあるビューに渡さない)。キーで変更した値も、設定の値として保存する。
  - 値は UserDefaults に保存する。保存済みの値が整数でない場合と、範囲の外の場合は、
    四捨五入して範囲の中の値として扱う(保存済みの値は、次に変更するまで書き換えない)。
    保存済みの値が数値でない場合は、13 として扱う。
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
- **異常の可視化**(黙って機能停止しない): 以下は**固定フッター**(一覧の下。上記)に
  警告行として常設表示する
  (切断はトレイ全体のグレー化が一次シグナルなので、一覧を優先し警告を下に配置する) —
  daemon と切断中(再接続バックオフ中。古いスナップショットを正常と誤認させない。
  **切断中はトレイ全体もグレー化**する)/ 通知権限が denied /
  **focus・reconcile のいずれかが TCC エラー(exit 3)を返した**(reconcile が権限で沈黙すると
  backstop ごと失われるため、focus に限定しない)。
  **通知権限の denied 判定は、ポップオーバーまたはウィンドウを表示するたびに再評価する**(起動後に許可を変更しても
  アプリの再起動なしで警告行の表示/非表示に反映される)。
  また、アプリが実行する subprocess の失敗(非ゼロ exit)は exit code と stderr を os_log に記録する
  (黙って握りつぶさない — 本項の大原則)
- **daemon のライフサイクル管理**: アプリ起動時に socket へ接続し、応答があれば**既存 daemon にアタッチ**する
  (アプリのクラッシュ等で残った orphan daemon もここで回収される。daemon 側の二重起動防止は §4.2 の
  起動シーケンスが担う)。応答がなければ同梱の `shiibar-ccd` を spawn し、バックオフ再接続で繋ぐ。
  アプリ終了(Quit)時は `shutdown` を送って daemon も止める
- **ログイン時起動**: `SMAppService.mainApp` を使う。**初回起動時のみ自動登録**する
  (実施済みかだけを UserDefaults に記録し、以後は自動登録しない — OFF にした選択を次回起動で
  上書きしないため)。以降の ON/OFF は Settings ウィンドウの「Start at Login」トグルで行い、
  チェック表示は毎回 SMAppService の status を読む(システム設定側で変えられてもずれない。
  自前フラグを状態の正にしない)。install スクリプトはアプリを一度起動するだけで、
  Login Items API を直接は呼ばない
- **reconcile の実行**: アプリは `shiibar-cc reconcile` を **(1) 起動時 / daemon 再接続時、(2) 定期
  (`NSBackgroundActivityScheduler`、間隔 約 60 秒・tolerance 30 秒。§9。システムスリープ中は OS が
  スケジュールを止め、復帰後に自然に再開する — 自前の画面状態検知はしない)、(3) 手動 Rescan(見出し行の
  ⌄ メニュー / アプリメニュー。⌘R)** で呼ぶ(§3.5/§8.22)。これで hooks の取りこぼしによる
  status ドリフト(「working のまま固まる」等)と daemon 不在中の穴(幽霊・見逃した waiting)を自己修復する。
  定期実行はフィードバック表示を出さない(「Rescanning…」等は手動 Rescan 専用。
  osascript 走査を回し続けるコストを避ける)。hooks 主軸のリアルタイム性は保ったまま backstop になる。
  **手動 Rescan にはフィードバックを出す**: 実行中は「Rescanning…」、正常終了後は「✓ Rescan done」を
  一定時間(§9)メッセージ行に表示して消す。件数は出さない。TCC エラー(exit 3)は警告行(上記)のまま、
  それ以外の失敗は同じ場所に「Rescan failed」を一時表示する。見た目は window-design.html
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

会話の履歴をフォルダ横断で**一覧し**(browse)、**検索し**(search)、**全文を表示し**(read)、新しい
ターミナルウィンドウで**再開**(Resume)または**分岐**(Branch)する機能。消費者は 2 つ —
**アプリとスクリプト(CLI)** — で、どちらも同じ CLI コマンドを使用する。
ポップオーバーとウィンドウ(§4.5)では、History の区画と会話ペインがこの機能の表示である。
**daemon・プロトコル・hooks・状態モデルには変更を加えない**(§8.34)。状態モデルとの接点は
2 つ — (1) Running の行(daemon の一覧)と session_id が一致する会話を History から除く
(2) Resume / Branch のターミナル選択と Jump が、アプリが購読済みのエージェント一覧を参照する
(下記「Resume と Branch」。§8.47)。
会話の識別子は Claude Code の session ID をそのまま使用する。見た目の正は `docs/window-design.html`。
**会話ペイン**は、1 つの会話を表示する領域(ヘッダ・検索バー行・メッセージ面・下部パネル)の名前である。
1 列では詳細ページ、2 列では右の列が会話ペインになる(§4.5「幅による切り替え」)。

#### 索引と検索(CLI・Rust)

- **不変条件**: `conversations` の各コマンドは **transcript の現在に対して答える**。DB は
  アクセス時に自己更新される内部キャッシュ(冪等・クラッシュ安全)であり、利用者が索引の状態を
  意識する必要はない(§8.34)
- **データ源**: `~/.claude/projects/<cwd スラグ>/<session_id>.jsonl`(Claude Code の transcript。§7-6)。
  **非公開フォーマットへの読み取り専用の依存**であり、Claude Code の更新で一覧・閲覧が壊れ得る
  (README に明記する)。**transcript と pid ファイルの知識、SQLite は `crates/shiibar-cc` 内の
  conversations モジュール一箇所に閉じ込める**(iTerm2 の知識を iterm2 モジュールに閉じるのと同じ
  局所化 — 設計原則 2)。アプリは CLI を呼んで JSON を読むだけで、Swift に transcript パースも
  SQLite も持たない(daemon に対する表示クライアントの姿 — 設計原則 4 — が索引に対しても成り立つ)
- **CLI 動詞**(契約・JSON スキーマは §4.4): `conversations index` / `conversations search` /
  `conversations show`。**外部との境界は各コマンドの出力 JSON だけ**で、DB スキーマは Rust の私有
  (自由に変更できる。NDJSON プロトコルが daemon の安定境界であるのと同じ関係)
- **索引の内容**: **全会話**(実行中も含む)+ **live/past フラグ**。絞り込みは消費者の責任。
  会話ごとに: タイトル(**最後の `custom-title` → 無ければ最後の `ai-title` → 無ければ最初の
  ユーザープロンプトの先頭 1 行・80 文字(80 文字は §9 の task と同値)→ それも無ければ null**。
  フォルダラベルへの最終フォールバックは表示側の責任。§7-6)/ cwd(アクティブ経路上の最初の非空値)/
  最終更新(transcript の mtime)/ 発話列(出現順 + 役割 + 全文)/ 最後の人の発話
  (発話列の最後の人の発話の先頭 1 行・80 文字。search の `last_prompt` — §4.4)。
  発話列に入れるのは**アクティブ経路上の、人の発話と Claude のテキスト返答のみ**。
  除外: ツール実行・実行結果・システム行・スラッシュコマンド出力・`<task-notification>` の
  自動 wake-up・sidechain(§7-6)。書きかけの行(実行中の末尾)や壊れた行は skip して続行する
- **アクティブ経路**: 葉 = **ファイル内で最後に現れる、完全な・sidechain でない user / assistant 行**
  (この規則が成り立つ根拠と実測は §7-6)。そこから `parentUuid` を遡って集める。**遡行は uuid を持つ
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
  一覧に出た会話は索引済みなので常に読める): **DB パスから導出したロックファイル
  (`<DB パス>.lock`)への `flock` で全体を排他**(プロセスが死ねば OS が解放 — 立ちっぱなしが
  起きない。DB パスの注入 — テスト分離 — に自動で追従する)→ (1) `~/.claude/projects` を stat 掃引し、`(パス, mtime, サイズ)` が変わった
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
  返すのは会話ごとに 1 件・6 フィールド(§4.4)。並びは常に新しい順。クエリ無し(trim 後空)は全件(browse)
- **全文の取得**(`conversations show <session-id>`): その会話の発話列全体を返す(切り詰めは
  表示側の責任 — DB は全文を持つ)
- **索引の更新**(`conversations index`): 追いつきだけを実行する動詞(+ `--json` で進捗ストリーム —
  §4.4)。構築の進捗は meta 表にコミットごとに記録し、**ロック待ちになった `index` は待っている間
  その進捗を読んで自分のストリームとして中継する**(呼び出し側は子プロセスの管理を持たなくてよい)。
  処理は新しい順

#### History の区画と会話ペイン(アプリ)

- **History の区画**(§4.5 の一覧の下側): `conversations search` の結果から、**Running の行と
  session_id が一致する会話を除いたもの**を表示する(同じ会話を 2 つの区画に表示しない。
  除外は表示のたびに適用するので、Running に行が現れた時点で、対応する History の行は消える)。
  **並び**: スター付きの会話が先、その後に残りの会話。それぞれの中は新しい順(`updated_at` の降順 =
  search が返す順)。
  **表示する行は、この並びの先頭から §9 の上限までである**。上限を超えた会話があるときは、
  History の最後の行の下に、表示していない会話の数を 1 行で表示する — クエリが空なら
  `N more — search to narrow down`、検索中なら `N more — refine your search`(この行は選択できない)。
  区画の見出しの行数、↑ / ↓ の移動、詳細ページの位置は、表示している行だけを対象にする。
  上限は表示だけに適用する(search の結果そのものは制限しない — スターの整理と、Running の行の
  タイトルの取得は、結果の全体を使用する)。
  行は 3 行 — **1 行目 = タイトル**(null はフォルダラベルで代替する)/
  **2 行目 = フォルダラベル + 経過時間**(ラベルは §4.5 と同じ末尾 2 要素規則)/
  **3 行目 = その会話で最後に自分が送った発話**(search の `last_prompt`。先頭に `❯` を付ける。
  null なら空行にして、行の高さをそろえる)。**3 行目は検索中も最後の発話のままである**
  (ヒットした箇所の抜粋に差し替えない)。行頭のスロット(Running の行で状態記号を表示する位置)は
  スター用である(下記)。下部パネルの主ボタンは Resume である(§4.5「実行のボタン」)。
  - **live の会話が History に残る場合**(daemon が追跡していない会話 = 対応外ターミナル
    (VS Code のターミナル・SSH 等)で実行中 — §8.11): 2 行目の末尾に `running` の淡いテキスト印を
    表示し、下部パネルの主ボタンは **disabled の Jump**(ツールチップ
    `Running in a terminal Shiibar CC can't drive` — README と同じ語彙)にする。Branch は押せる
  - **cwd の無い会話**は Resume と Branch を disabled にする(resume は cwd 必須 — §4.4。
    disabled の間もツールチップは `Resume` / `Branch` のままである)
  - **空状態**: Running と History の両方に行が無いときだけ、一覧の位置に 1 行を表示する —
    クエリが空なら `No conversations`、検索中なら `No matching conversations`。
    索引の全構築中(下記「ポップオーバーまたはウィンドウを開いたとき」)と、起動後に最初の search の結果を
    受け取るまでの間は、この 1 行を表示しない
- **スター**(§8.49): History の行の行頭スロットに表示する。行にホバーすると輪郭だけの星を表示し、
  クリックするとスターが付く(黄色の塗りの星になり、ホバーしていなくても表示する)。
  もう一度クリックすると解除される(ツールチップは `Star` / `Unstar`)。
  スロットのクリックでは行を選択せず、詳細ページも開かない。
  スターの変更は直後に並びへ反映する。
  **スターはアプリの表示設定**であり、session_id の集合を UserDefaults に保存する。CLI・索引・
  Claude Code 側には書き込まない(索引 DB は自動で再構築されるキャッシュなので保存先にしない)。
  スター付きの会話が Running にある間、星は表示しない(行頭は状態記号)。スターは保持し、
  会話が終了して History に戻るとスター付きの位置に表示する。
  Branch で作成した会話はスターを引き継がない(別の session_id になる)。
  **スターは会話の削除を防がない**: Claude Code が保存期間を過ぎた transcript を削除すると(§7-6)、
  その会話は一覧から消える。クエリが空の一覧を取得した時点で、一覧に無い session_id のスターを破棄する
- **検索の適用範囲**: クエリが有効な間、**Running の行は、session_id が search の結果に含まれる行だけを
  表示する**(session_id が空の行は表示しない)。History は search の結果(上記の除外後)である。
  一覧にはヒットの抜粋も件数も表示しない(会話ペインがヒット位置を表示する。§8.49)。
  区画の見出しの行数は、検索中は表示している行の数になる
- **検索欄(見出し行)**: 外観(角丸の地・枠・虫眼鏡のアイコン)はアプリが描画し、その中に枠なしの入力欄を
  配置する(大きさは `window-design.html`。OS 標準の検索欄の外観は、指定した高さにならないため使用しない)。
  **消去のボタン**: 検索欄に文字がある間だけ、検索欄の中の右端に、塗りつぶした円に × を描いた
  12pt のボタンを表示する。文字が無い間は表示せず、場所も空けない。入力した文字は、ボタンの下に入らない。
  ボタンを押すと、検索欄の文字を消去し、検索欄にフォーカスを移す。消去の後の動作は、キーで文字を
  全部削除したときと同じである。日本語入力の変換中に押した場合は、変換中の文字も消去する(確定しない)。
  ツールチップは `Clear`、
  アクセシビリティの名前は `Clear search` である。ボタンは、キーのフォーカスを受け取らない。
  検索欄が無効の間(全構築中)は、ボタンを表示しない。
  インクリメンタル。デバウンス(§9)後に `conversations search --json` を
  subprocess 実行し、進行中の実行はキャンセルして新しいクエリを投げる。
  クエリは送信前に NFC へ正規化する(CLI 側でも正規化する — 二重の防御。§8.38(12))。
  **日本語入力(IME)の扱い**: 変換が未確定(marked text)の間は検索を発行せず、
  **確定した時点で必ず発行する**(ひらがなの中間状態で無駄な検索が走らない。§8.38(12))。
  **⌘F は検索欄にフォーカスを移す**(文書内検索の標準ショートカットの受け皿 —
  検索欄が文書内ヒットのナビゲーションも兼ねる画面なので。1 列の詳細ページでの動作は §4.5「キー操作」)。
  **検索は 1 つである**: 一覧を絞り込む検索文字列が、そのまま会話内のヒットの検索文字列になる。
  会話内だけを別の文字列で検索する機能は持たない(§8.49)。**trim 後に有効な語
  (2 文字以上)が 1 つも無い間は search を発行せず** browse 一覧のまま(プレースホルダ
  `Search (2+ characters)`)。検索欄の隣に **⟳ ボタン** — 同じクエリで search を再実行する
  (よそで終わった会話を拾う手動リフレッシュ。Rescan と同じ文法。ツールチップは `Refresh`)。
  **押下には必ず見える反応がある** — ボタン自体が状態を持つ(§8.42/§8.44):
  静止時は背景なし・ホバーでグレーの地が浮く / 押下で沈む / **実行中は矢印グリフが回転**して
  disabled(この回転はリロードボタンの標準文法で、working のグリフ循環スピナー ✻ とは別物)。
  回転は**必ず真上(0°)から始まり**、止まるときは**回転の切れ目まで回り切ってから**通常状態に
  戻る(周期・最低 1 回転は §9。検索は数十 ms で終わるため、回転が知覚できる長さを保証しつつ、
  開始も終了も真上で揃えて途中角度からの飛びを作らない — §8.43/§8.44)。あわせて実行中は
  メッセージ行(§4.5「固定フッター」)に `Refreshing…`、**完了後は `Updated · N conversations` を 2 秒**
  (Rescan の一時表示 — §9 — と同値。N は search の結果の件数で、Running に表示している会話も含む)
  表示してから消す。
  **search がエラー終了したときは前回の結果を維持**して、メッセージ行にエラーを表示する
  (打鍵途中の一過性の失敗で一覧を消さない)
- **History を再取得する契機**(search の再実行。§8.49): ポップオーバーを開いたとき /
  ウィンドウを開いたとき / **ウィンドウが key になったとき**(他のアプリから戻った時点で最新にする)/
  打鍵 / ⟳ / アプリからの Resume・Branch の成功直後 / **Running の行が消えたとき**(`agent_removed`。
  終了した会話を History に表示するため。直後の再取得では、終了の途中のプロセスがまだ生存していて
  会話が live と判定される場合があるので、§9 の時間の後にもう 1 回再取得する)。
  search の結果は、これ以外の契機では更新しない
  (Running の行と一致する会話の除外と、スターによる並びは、search を再実行せずに直後に反映する)。
  FSEvents による監視は持たない。複数の契機が重なったときは 1 回にまとめてよい。
  **表示中の会話が結果に残っている間、会話ペインの内容は再取得では変化しない**(下記「表示の状態規則」)
- **会話ペインの表示**: 会話ペインが表示する会話が決まると(1 列で詳細ページを開いたとき、
  2 列で行を選択したとき、1 列の詳細ページで ⌥↑ / ⌥↓ またはヘッダの前後のボタンで会話を切り替えたとき)、`conversations show` で
  **全文を 1 回で取得**し、古い順に表示する(下端 = 最新)。スクロールは自由。
  `session_id` が空の行では、show を実行しない(§4.5「行のクリック」)。
  show が exit 2(索引に無い — 直前に消えた等)または exit 1 のときは、メッセージ面に
  1 行のエラーを表示する(一覧は維持)。
  **会話ペインのヘッダ**は 1 行目 = タイトル、2 行目 = **ホーム相対のフルパス**
  (`~/Documents/blog` 形式)+ 経過時間 — 一覧の 2 要素ラベルより詳しくするのは、
  Resume で開き直すフォルダをここで確定できるようにするため。
  **1 列の詳細ページのヘッダ**は、タイトルの左に**戻るボタン**(一覧のページに戻る。← と同じ。
  ツールチップ `Back`)、右に**一覧の中での位置**(`2 / 4`。表示している行の中で何番目か /
  表示している行の数)と**前後の会話へ移動するボタン**(⌥↑ / ⌥↓ と同じ。端では disabled。
  ツールチップ `Previous conversation` / `Next conversation`)を配置する。
  2 列の右の列のヘッダには、この 3 つを配置しない(左の列が同じ役割を持つ)。
  ヘッダ下の区切り線は検索バー行の有無によらず常時出す(§8.38(8))。
  **描画の文法**(見た目の正は window-design.html。行間・段落間・ブロック間隔・帯の余白は、
  同ファイルの CSS 値が実装の正である — §8.39): どの発言も、先頭に**役割のラベルの行**
  (自分の発言は `You`、Claude の発言は `Claude`)を表示し、その下に内容を表示する(§8.49)。
  `You` のラベルは青、`Claude` のラベルは二次色である。
  **自分の発言 = 全幅の帯**(ラベルと発言に帯の地を付ける。発言は通常ウェイト・13.5pt(文字の大きさ 13 のとき)。
  発言そのものをそのまま表示する — Markdown 描画はしない)/
  **Claude の発言 = Markdown を描画した本文**(地は付けない)。
  1 つの依頼に Claude の発言が連続するときも、すべての発言にラベルを付ける(発言の境目を示す)。
  メッセージ間のツール実行は何も描かない。
  **ラベルは描画後テキストに含めない**(ヒット計算・畳み境界の対象外 — 「Claude」で検索しても
  ラベルにはヒットしない)。
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
  **‹ › のセグメンテッドコントロール**(ツールチップは `Previous match` / `Next match`)。次(`›`・⌘G)= 新しい方へ /
  前(`‹`・⇧⌘G)= 古い方へ。**端まで行ったら反対側へ折り返す**(⌘G の慣習)。
  **`N of M` の N は、会話の先頭(最も古い出現)を 1 として数える**。初期位置は最新の出現なので、
  開いた直後のカウンタは `M of M` になる。
  **1 列の詳細ページの検索バー行は、左端に検索文字列を文として表示する** — `Matches for “tag”`
  (`Matches for` は淡い色、引用符で囲んだ検索文字列は通常の色。長い検索文字列は途中を省略する)。
  詳細ページには検索欄が無く、何を検索しているかを確認できないためである。表示だけで、ここでは変更できない。
  入力欄と区別できるように、背景・枠・虫眼鏡のアイコンを付けない。この行では、カウンタと ‹ › を右端に配置する。
  2 列では検索欄が表示されているので、検索バー行に検索文字列を表示せず、
  コントロールは**内容サイズ・左寄せ**にする(バーの幅いっぱいに伸ばさない — §8.38)。
  **ヒットが 1 件でも、押下のたびに現在のヒットへスクロールする**
  (現在位置が変わらなくても再スクロール — 画面を離れても戻れる)。
  クエリを打ち替えたらハイライトとカウンタは再計算するが**スクロールは動かさない**。
  **ミニマップ**(§8.39): 右端の幅 20pt の列に会話全体の略図(帯 = 濃い縞・本文 = 淡い塊・
  コードブロック = 中間の塊。文字は描かない)を常時表示し、**それ自体がスクロールバーを兼ねる** —
  いま見えている範囲を半透明のグレー帯(つまみ)で示し、ドラッグでスクロール・ホバーで濃く・
  地のクリックでその位置へジャンプ。会話ペイン内の OS スクロールバーは表示しない(位置表示を
  二重にしない)。検索中は**ヒットの線**(現在位置だけ濃く)をミニマップ上に重ねる —
  ヒット分布の表示はミニマップが担う。位置は実レイアウト由来。
  **本文の文字はミニマップの手前 8pt で折り返す**(帯・コードブロックの背景の伸び方は
  変えない — 文字だけが隙間を取る。§9)
- **表示の状態規則**: 選択中の会話が結果に残っている間、一覧の再取得は会話ペインの表示を変更しない
  (全文を再取得せず、スクロール位置も変更しない。選択は session_id で保持する)。
  選択中の会話が結果から消えたときは、§4.5「行の選択」の規則で選択なしになる(1 列の詳細ページは
  一覧のページに戻り、2 列の右の列は `No conversation selected` を表示する)。**スクロール
  位置は会話ごとに記憶**(アプリを終了したら破棄。復帰時は記憶が初期位置に優先する)。
  **500 文字(§9。描画後テキストで数える)を超えるメッセージは畳んで `Show full message` で展開**。
  畳みの見えない部分にヒットがあるときは展開ボタンに件数バッジ(`N matches`)を付ける。
  畳まれた部分へのヒットもカウンタに数え、‹ ›(⌘G / ⇧⌘G)でジャンプしたら自動で展開する。
  **展開したメッセージの末尾には `Show less`** — 畳み直しで視点がそのメッセージから飛ばないよう
  スクロールを寄せる。展開状態は選択の切り替えで破棄
- **下端(最新)の手がかり**(§8.39): 最後のメッセージの下に、罫線ではさんだ淡い一行
  **`Latest message · <経過時間> ago`**(終端マーカー)— 開いた瞬間に「ここが末尾で、いま最新を
  見ている」が読める。**上に続きがある間だけ**ヘッダの下に薄いスクロールシャドウを出す
  (最上部まで遡ると消える)
- **会話ペインの文字の大きさ**: 会話ペインは、Settings の Text size(§4.5「文字の大きさ」)に従う。
  本文の文字の大きさは、設定の値(pt)である。メッセージ面のほかの文字(ラベル、自分の発言、見出し、
  コードブロック、表、展開のボタンと件数バッジ、下端の一行)、発言のコピーのアイコン、上下の余白は、
  13 に対する比率で連動する(`window-design.html` の CSS 値は、13 のときの値)。
  左右の余白(箇条書きの字下げを含む)、角の半径、枠線、ミニマップの幅、上端の影の高さは固定である。
  本文の幅の上限と表のセルの幅の上限は、文字数で指定しているので、文字の大きさと一緒に変化する。
  文字の大きさが変化しても、ハイライトとカウンタの意味は変化しない(位置は文字単位で、描画の大きさと無関係)
- **描画エンジン(会話ペインのメッセージ面)**: アプリ同梱のページを表示する WKWebView(システム
  WebKit — 追加依存なし)。ヘッダ・検索バー行・下部パネル・一覧はネイティブのまま(§8.38)。規律:
  transcript 由来の文字列は **textContent 経由でのみ** DOM に入れる(HTML 文字列に混ぜない)/
  nonce 付き CSP で外部ロードと混入コードを遮断 / ページ遷移は全キャンセルし、本文中のリンクは
  既定ブラウザで開く / **データストアは非永続**(会話内容を WebKit のキャッシュとしてディスクに
  残さない)/ **意味論は Core が正**: 描画後テキスト・ヒット位置・畳み境界・バッジ件数は
  すべて Swift 側の計算値を渡し、ページは受け取った境界で切って描くだけ(JS では再計算しない)。
  ログは**配信・描画の異常だけを既定レベルの unified log に残す**(正常系の毎回のログや会話内容は
  記録しない。読み方は DEVELOPMENT.md「ドッグフーディング運用」)
- **選択とコピー**: メッセージをまたぐ連続選択ができる(文書として扱う)。役割のラベル・
  展開/畳みボタン・コピーのボタンは選択・コピーに含めない。**どちらのコピーも対象は選択範囲だけ** —
  選択が無ければ何もコピーできない。右クリックメニューは
  **Copy(⌘C 併記)/ Copy as Markdown(⇧⌘C 併記)の 2 項目を常に出し**、選択が無い間は
  両方 disabled(Look Up 等の標準項目は取り除く)。
  **⌘C / ⇧⌘C はペイン自身がキーを受けて処理する**(ビューの performKeyEquivalent はメニュー配達より
  先に走る — Edit メニュー(§4.5/§8.41)の Copy と二重処理にならない。§8.38)。
  **Copy = WebKit 標準のコピー(`copy:`)を呼ぶだけ** — 書式(リッチテキスト)も含めて
  WebKit に任せ、自前の書き出し経路を作らない(§8.38)。
  **Copy as Markdown = 選択範囲を、描画に使ったブロック構造とインラインスタイルから Markdown に
  直列化**したもの(見出し・リスト・コードブロック・表と、インラインの code・強調・打ち消し・
  リンクを復元する。原文の文字列一致ではなく「選択した部分の Markdown 表現」)
- **発言ごとのコピー**(§8.49): 各発言のラベルの行の右端に、コピーのアイコンボタン(ツールチップ `Copy`)を
  常に表示する。
  押すと**その発言の全文**(`conversations show` の `text` そのまま —
  Claude の発言は Markdown の原文。畳まれている発言も全文)をプレーンテキストでコピーする。
  選択範囲には影響しない。押した後はアイコンを一定時間(§9)チェックマークに替えて反応を示す。
  コピーのボタンは、選択・コピーの対象に含めない
- **下部パネル**(1 列の一覧のページの下端と、会話ペインの下端。常に同じ高さ): 選択中の行を対象にする
  Jump / Resume / Branch を、ラベル付きのボタンで表示する(§4.5「実行のボタン」)。
  右端が主ボタン(**Resume** または **Jump**)、その左が **Branch**(副ボタン)。
  主ボタンは選択中の会話の状態で決まる(§8.48 / §8.49):
  - Running の行にある会話 → **Jump**
  - History の会話 → **Resume**
  - History に残る live の会話 → **disabled の Jump**(ツールチップ
    `Running in a terminal Shiibar CC can't drive`)

  **1 列では、パネルの左側にキーの案内を配置する**。一覧のページの案内は §4.5「固定フッター」のとおりで、
  詳細ページの案内は `⌥↑↓ Prev / Next` / `← Back` である(見た目は同じ)。
  一覧のページで行を選択していない間は、ボタンを表示せず、キーの案内だけを表示する
  (パネルの高さは変更しない)。一覧のページと詳細ページで、ボタンの位置と大きさは同じである。
  2 列の右の列では、左側には何も配置しない(キーの案内は左の列のフッターにある)。
  **ボタンの中に、ラベルに続けてショートカットを表示する**: 主ボタンは `Resume ↩` または `Jump ↩`、
  Branch は `Branch ⌘↩` である(ショートカットの記号は、ラベルより淡い色で表示する。disabled の間も表示する)。
  検索欄にフォーカスがある間は、ショートカットの記号を表示しない(その間の Enter は一覧にフォーカスを移す操作で、
  ⌘Enter は何もしないため)。記号の有無でボタンの幅と位置を変更しない。ボタンのクリックは、フォーカスの位置に
  関係なく有効である。
  **disabled の見た目は標準の灰色の器**(prominent のまま淡くしない。§8.42)。
  **Resume と Jump は同幅**(長い方のラベルに揃えて固定 — 行を移ってボタンが替わっても
  端の位置とクリックターゲットが移動しない)。cwd の無い会話では Resume と Branch を disabled にする。
  **ボタン状態を導出するのは、行の選択時・History の再取得時・Running の行の増減時**である
- **Resume と Branch**: `shiibar-cc resume --cwd <cwd> --terminal <t> <session_id>` を subprocess
  実行する(アプリの操作は CLI 経由の原則 — §8.24)。**Branch は同じコマンドに `--fork` を付ける**(§4.4)。
  成功すると、ポップオーバーは閉じ、ウィンドウは閉じない(§4.5)。成功直後に search を再実行する。開始された会話は
  SessionStart の hook で通常どおり Running に現れる(Resume した会話は、その時点で History から
  除かれる。Branch で作成された会話は新しい session ID を持つ)。
  **Branch は実行中の会話にも実行できる**(その時点までに記録された会話のコピーから始まり、
  元の会話には影響しない — §7-6)。
  **どのターミナルで開くかは観測で決める**(設定も質問も持たない。§8.47): エージェント一覧の
  最新エントリ(`last_seen` 最大)の target prefix → それが無ければ最後に観測した種別
  (UserDefaults に記憶 — エントリを観測するたび更新)→ それも無ければ `iterm2`。
  一方のターミナルしか使用しない人には常に正しく、乗り換えにも自動で追随する。
  **一覧の表示からクリックまでの時間差で、他の場所で resume された会話への二重 resume は防がない**
  (意図的な割り切り。§8.34)
- **Jump**: 選択中の会話に対応する Running の行の target へ `shiibar-cc focus <target>` を実行する。
  成功時の seen 送信・TCC(exit 3)の扱い・該当なし(exit 2)でエラーを表示しない点は、
  §4.5「実行のボタン」のとおりである。成功すると、ポップオーバーは閉じ、ウィンドウは閉じない。
  Jump の後に search の再実行はしない
  (会話の状態は何も変化しないため)。**事前チェックは持たない** — 行き先の有無は focus の全走査が
  確認であり、タブが残っていれば claude が終了していても着地する(focus の意味は「タブへ行く」。§8.48)
- **索引の温め**(表示とは独立の背景動作): アプリ起動時に `conversations index` をキック(失敗は
  静か — ログのみ)+ `NSBackgroundActivityScheduler` で約 10 分ごと(§9。§8.22 と同じ流儀)。
  目的は search 時の追いつきを常に小さく保つことで、表示の鮮度はこれに依存しない
- **ポップオーバーまたはウィンドウを開いたとき**: `conversations index --json` を実行し、
  進捗(`Indexing N of M…`)をメッセージ行に表示する。完了したら現在のクエリ(空なら全件)の
  search で History を表示する。全構築でない index の実行中は、前回の History を表示したままにする。
  ウィンドウが key になったときも、同じく index を実行してから search を実行する。
  **全構築中(`start` の `full_build` が true — §4.4)は検索欄を無効にして進捗だけを表示する**
  (構築中の部分結果は表示しない — §8.34)。
  index がエラー終了したら、メッセージ行にエラーを表示する(次の契機で回復)。前回の History があるときは
  表示したままにし、無いときは History を表示しない。
  Running の区画は index を待たずに表示する(daemon の一覧であり、索引に依存しない)。
  行の選択は §4.5「行の選択」の規則に従う。1 列では、利用者が行の `>` ボタンを押すか、一覧にフォーカスがある間に → を押すまで
  詳細ページを開かない
- **メッセージ行**(固定フッター。§4.5): **表示の優先順位**は、索引の進捗 > エラー >
  一時表示(`Refreshing…` / `Updated · N conversations` / Rescan の結果。表示時間は §9)である。
  どれも無いときは、行ごと表示しない。エラーは、次に成功した取得で消える
- **アンインストール**: DB は状態ディレクトリ内なので、既存の一段アンインストール(§8.20)が
  そのまま消す。追加の削除対象はない

## 5. リポジトリ構成(monorepo)

全マイルストーン完了時点の構成。

```
shiibar-cc/
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
│   └── release/            # リリースビルド用(タグ⇔バージョン検査・署名付きビルド・リリースノート生成・draft の本文差し替えと publish。§8.28)
├── fixtures/               # 実 hook JSON の採取物(M1 で採取・コミット。統合テストが再生する)
├── docs/
│   ├── DESIGN.md           # 本書(挙動の正)
│   ├── menubar-design.html # トレイアイコン確定デザイン(見た目の正)
│   ├── window-design.html  # ポップオーバーとウィンドウの確定デザイン(見た目の正。§4.5 / §4.6)
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
     (2026-07-07、この設定が OFF の実機で確認: TCC は許可済み・Setup Check 全緑でも focus が「効かない」見た目になり、
     ON に戻すと解消)。設定の実体は NSGlobalDomain の `AppleSpacesSwitchOnActivate`
     (明示 `0` = OFF。未設定は既定 ON)→ doctor がチェックする(§4.4)
   - **`activate` が select の後だと、上記設定が ON でも Space をまたげない**(2026-07-17 実機確認):
     iTerm2 **以外**のアプリがアクティブな状態から focus すると、select → activate の順では
     activate のアプリ切り替えが「今の Space にある iTerm2 ウィンドウ」を前に出し、select 済みの
     別 Space のウィンドウが負ける(スクリプトは FOUND / exit 0 のまま — 見た目だけ誤着地)。
     iTerm2 がアクティブなままの focus(プルダウンはアクティブアプリを奪わないパネル)では
     発生しない — Conversations の Jump(§4.6)がこの条件を初めて日常動線にして発覚。
     **一致を見つけたら activate → select の順**にすると別 Space へ正しく遷移する(同日実証)。
     activate は一致分岐の中でのみ実行するため、該当なし・未起動時に何も動かさない規則(§4.3)は保たれる
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
   - **`--fork-session` による分岐**(測定 2026-11-14、Claude Code 2.1.323): プロセスが生存している
     セッションを、別プロセスから `claude --resume <id> --fork-session` で分岐できる。分岐先は、
     分岐の時点までに transcript に記録された会話を持つ**新しい session ID の transcript** として、
     同じ `<cwd スラグ>` のディレクトリに作成される(各行の `sessionId` はすべて新しい ID。分岐元を
     示すフィールドは確認できなかった)。分岐後、元のセッションへの追記は分岐先に現れず、
     その逆も同じ。測定では元のセッションを `claude -p` の stream-json 入力で生存させた
     (対話画面のセッションを対象にした測定は未実施)
   - **保存期間による削除**(2026-11-14): Claude Code は `cleanupPeriodDays`(既定 30 日・最小 1。
     `settings.json`)を過ぎた transcript を自動で削除する(公式ドキュメント)。日数の起点は
     ドキュメントに記載が無い。作成 59 日前・最終更新 20 日前の transcript が残っている事例があり、
     作成時刻は起点ではない
   - **観測未の残り**: `sessions/<pid>.json` のクラッシュ時の残り方のみ(read-only では再現不能。
     残っても 2 段生存チェックが無害化するため設計影響なし)
7. **Terminal.app の実挙動** — ✅ 実機で検証済み(2026-07-16、macOS 14.5 / Terminal 2.14。M40 スパイク):
   - タブ内の環境は `TERM_PROGRAM=Apple_Terminal`。`TERM_SESSION_ID`(素の UUID)もあるが、
     **AppleScript の tab クラスに id 系プロパティが存在しない**(全プロパティを辞書で確認)ため
     外から解決できない → 内(hook 環境)と外(AppleScript)の共通鍵は **tty のみ**。
     tab には `processes`(タブ内のプロセス名リスト)プロパティもある(辞書で存在を確認。
     実行時の中身は未検証 — §8.47 の安全弁候補)
   - シェルの tty と AppleScript の `tty of tab` は完全一致(`/dev/ttysNNN` 形式)。
     `ps` の tty 列は `/dev/` 無し(`ttysNNN`)なので比較時に前置する
   - **hook プロセスは制御端末を持たない**(`ps` で `??` — claude が端末から切り離して起動する)。
     親連鎖は `hook の sh(??) → claude(ttysNNN) → zsh → login → Terminal.app` で、
     **最初に制御端末を持つ祖先 = claude 本体**。実 hook(SessionStart / Stop)で確認 —
     target の tty は祖先 walk で取る(§4.1)
   - focus は「全 windows × 全 tabs 走査 → `tty of tab` 一致 → `set selected` +
     `set frontmost of window`(設定可能と実測)+ `activate`」で成立。ウィンドウ間・
     同一ウィンドウのタブ間とも目視確認済み(この目視は activate 末尾の順で行った)。
     一致なしは何も動かさない。現行仕様の順は activate 先行(§4.3 — 理由は §7-1 の
     Space またぎ実測)。**activate 先行の順での Terminal.app の動作と Space またぎは
     実機で確認済み**(2026-07-17、M42 スモーク: 別アプリがアクティブな状態から
     別 Space の Terminal.app タブへ正しく遷移する)
   - **Cmd+T のタブは AppleScript には別 window(各 1 タブ)として見える**(AppKit のウィンドウタブ機構。
     タブグループは bounds が同一)。旧来の 1 window 複数 tab の形も存在し得るため、走査は常に全 window×全 tab
   - split pane(Cmd+D)は**同一セッションの表示分割** — 分割の前後で tty 一覧が不変(実測)。
     pane 単位のセッションは存在しない
   - `application id "com.apple.Terminal" is running` の照会は Terminal.app を起動させない(実測)。
     `do script` は起動させる → focus / 走査は is-running ガード必須(iTerm2 と同じパターン)
   - VS Code への env 相続は個別には未測。構造的に「間違ったタブに飛ぶ」経路が無い:
     `TERM_PROGRAM` は VS Code が `vscode` で上書きし(§7-1 で実測済み)report が drop、
     仮に通っても VS Code の pty は Terminal.app のタブ一覧に無いので focus は「該当なし」・
     reconcile は skip。iTerm2 の UUID 相続と違い、相続される値(`TERM_SESSION_ID`)を
     target に使っていないため、誤誘導の材料が残らない

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
`focus -`(ジャンプ元へ戻る)とメニューの「← 戻る」はドッグフーディングで
「呼び出す自然な瞬間がない」(飛んだ先は Claude の画面でシェルがなく、キーバインドを組まない限り使えない)と
判明して削除した。再検討の条件: 戻る操作の需要が実際の使用で発生し、キーバインドなどに割り当てる必要が生じたとき
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
- 追記: 最初に必要になったツマミは「バナーと音を独立に止める」だった。設定画面ではなく
  Settings サブメニューの独立ミュート 2 スイッチ(Mute Banners / Mute Sound。§4.5)として追加。
  細分化は引き続き post-v1

### 8.15 resume は実装後に削除した

- M3 として実装・実機テストまで行ったが、実運用での需要が「**そのフォルダで `claude -r` を叩く**」で
  完結していると判明した。shiibar 側の上乗せ(プロジェクト横断の履歴・正しい cwd での
  新タブ・実行中の除外)を使う場面が実際になく、続きの作業は新しいセッションで
  始めれば足りた
- 機能ごと削除: CLI `resume`・会話ファイルの存在フィルタ・iterm モジュールの `open_tab`・daemon の
  sessions 層(`sessions.jsonl` 追記・重複排除・compaction・`sessions` コマンド・proto の型)。
  実装は git 履歴にある
- **再検討の条件**: 終わった会話に戻りたい実感が繰り返し出たとき。そのときは CLI ではなく
  「past sessions の別一覧(いまの状態ビューとは分けた画面)から iTerm2 タブを開く」形を、
  実際の使われ方から設計し直す

### 8.16 通知の前面抑制を廃止した(M5)

- v1 は「配信直前に対象が前面なら通知しない」を持っていた(§8.10 で v1 に残すとした機能)が、
  実際の使用では、画面を表示していても別の作業をしている場合があり、その場合にも音での通知が必要なため廃止した
- 3 秒の遅延通知(発火時に unreviewed を再確認)は残す — 即応したときに通知を出さない仕組みはこちらで足りる。
  代わりに「対応した瞬間に配信済みバナーも消える」掃除(§4.5)が残骸を防ぐ
- 完了通知の音もこのとき追加した(waiting と同じ標準音・active レベル。ミュートは両方に効く)
- **再検討の条件**: 前面作業中の通知・音が「うるさい」実感に変わったとき。§8.14 の設定画面の
  ツマミ(レベル別オン/オフ)として戻すのが正しい形で、無条件の前面抑制には戻さない

### 8.17 セッションコスト表示は見送った(M5)

- ドロップダウンに Total Cost を出す案は、表示手段が無く見送った。
  フック(Stop / SessionEnd)は費用情報を運ばない(§7-3 と実 fixtures で確認)。
  transcript の解析は非公開仕様への依存になるためやらない。
  statusline 連携(statusline スクリプトには `cost.total_cost_usd` が渡される)は
  「statusline を設定した人だけ動く機能」になるため採らなかった
- **再検討の条件**: statusline を常用する運用になったとき(そのときは statusline → daemon への
  報告口を §4.2 に足す形で設計する)

### 8.18 配布は「公証済み .app」を選択肢に含めて公開準備で決める(M5)

- ローカルビルド + 自己署名(§4.5)は自分専用の前提。公開時の配布形態は
  Developer ID 署名 + 公証(Apple Developer Program)を選択肢に含めて公開準備の中で決める
  (Apple Developer Program には年会費が必要で、個人アカウントの Developer ID 証明書には
  登録者の本名が入る。どちらも受け入れる前提で、選択肢に含める)
- brew は cask(要・公証済みバイナリ)/ tap + formula(ソースビルド)の 2 形態がありうるが、
  需要が見えてから作る。v1 公開時の導入手順は clone + `scripts/install.sh` を README に書く
- Setup Check(導入チェック一覧の画面 — §4.5)は、将来のドロップ導入時に
  オンボーディング画面を兼ねられる構成にしておく

### 8.19 hooks は Claude Code プラグインで配布する(公開準備)

- `~/.claude/settings.json` への手動マージ(旧 `hooks/settings-snippet.json`)を廃止し、
  リポジトリ自体をマーケットプレイスにして(§4.1)`/plugin marketplace add` + `/plugin install` の
  2 コマンドで導入する。プラグインの hooks はユーザー設定と自動マージされ、settings.json を
  手編集させない・スクリプトで書き換えない、という M2 以来の制約を仕組みごと解消する
- `report.sh` はプラグインに同梱し `${CLAUDE_PLUGIN_ROOT}` で参照する。`~/.local/bin/report.sh` の設置は廃止
- 検討した代替: プロジェクト同梱の `.claude/settings.json`(そのリポジトリ内でしか効かず不適)/
  managed settings(組織 IT 配布用)/ 手動マージ(現行)。「全プロジェクト対象・手編集なし」を
  満たすのはプラグインのみ(公式ドキュメントで確認、2026-07-05)
- **再検討の条件**: プラグイン機構の仕様変更で hooks 同梱・`enabledPlugins` の形が壊れたとき

### 8.20 uninstall は一段のみ(`--purge` 廃止)(公開準備)

- 旧 `--purge` の内容(state dir / UserDefaults / 自己署名証明書 / iTerm2 TCC リセット)を既定にする。
  二段構えが守っていたのは「再インストール時の許可ダイアログ 2 回と Start at Login の再設定」だけで、
  install.sh がそれ以外を全自動で復元できる以上、「一時的に外す」段を分ける実需がない
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
  定期 reconcile を有効化する(実際の使用で、status が working のまま更新されない状態が発生したため)
- 実装は `NSBackgroundActivityScheduler`(間隔 約 60 秒・tolerance 30 秒。§9)。1 回のコストは
  `claude agents` + osascript 走査で 1 秒未満・稼働率 1% 未満のため、間隔は修復の速さだけで選んだ。
  「見ていないときに走らせない」は自前の画面状態検知ではなく OS のスケジューラに委ねる
  (スリープ中は発火せず、復帰後に自然再開 — 復帰直後の 1 回が取りこぼし修復として最も効く)
- 定期実行はフィードバック表示なし(手動 Rescan と区別。§4.5)

### 8.23 コスト表示は引き続き見送る(statusline 連携案を棄却)

- §8.17 の再検討条件(statusline の常用)は成立したが、statusline 連携案そのものを棄却した:
  statusline は、利用者が設定した環境でしか動作せず、
  環境によって動いたり動かなかったりする機能はこの道具の標準にできない
- hooks が費用情報を運ばないことを公式ドキュメントで再確認(2026-07-07。費用計測は OpenTelemetry 側の
  管轄で、hook payload には載せない意図的な分離)。transcript 解析をやらない判断(§8.17)も維持
- **再検討の条件**: hook payload が費用情報を運ぶようになったとき

### 8.24 ⌄ メニューに Clear badges と About を追加(§8.4 の例外を拡張)

- 「メニューバーには focus 以外の動詞を置かない」(§8.4)の例外を 2 つ増やす:
  **Clear badges**(未読フラグの一括クリア。未読が溜まったとき 1 件ずつ focus して消すのは手間が大きい)と
  **About**(アプリ名・アイコン・バージョンの確認先が無かった)。どちらも破壊的でなく確認フロー不要
- Clear badges は **unreviewed フラグだけ**を消し、通知センターの配信済み通知は触らない
  (通知は利用者が自分で消す。行クリックの focus がそのセッションの通知を消す挙動は従来のまま = 非対称は許容)
- CLI に `seen <selector>` を追加し、アプリは未読 target ごとにそれを呼ぶ(アプリの操作は CLI 経由、
  の原則を維持。§4.4)

### 8.25 既定ソートを Grouped にし、⌄ メニューをセパレーターで 3 グループ化した

- 既定の並びを Newest session から **Grouped** に変更:
  一目で知りたいのは「どれが waiting か」で、Grouped がそれを最短で示す(README のヒーロー画像も
  Grouped)。Sort by ラジオの並びも既定を先頭に(Grouped / Newest session / Recent activity)。
  保存済みの並び設定がある環境では挙動は変わらない(既定はフォールバック値)
- ⌄ メニューをセパレーターで 3 グループに: **操作**(Rescan / Clear badges)/
  **表示と設定**(Sort by / Settings / Setup Check…)/ **アプリ自身**(About / Quit)。
  About は §8.24 時点では Settings の直後に置いたが、macOS の慣習(About は Quit と同じ最下段)に
  合わせて移動した。7 項目にセパレーター 2 本 — 刻みすぎない 2/3/2

### 8.26 Settings ウィンドウを追加した(§8.14 の再検討条件が成立)

- §8.14 で「実際にいじりたいツマミが見えたとき、そのツマミだけ足す」と予約していた設定画面を
  追加。見えたツマミ = **イベント別(Waiting / Done)の通知音の種類**
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

- M5 で作った独立ミュート 2 スイッチ(§8.14 追記)のうち **Mute Banners を廃止**。
  「音だけモード」(バナーなしで音だけ)はアプリが音を直接鳴らすため **Focus・おやすみモードに
  従わない唯一の経路**だったが、Focus 中に音を出すアプリは行儀として存在しない
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
  (グリフ循環スピナー `·✢✳✶✻✽` / 静止した `✻` / `!`)に統一した。
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

- §8.3 の再検討条件が成立(一覧を常に表示しておく需要が、
  実際の使用で発生した)。ドロップダウンと同じ一覧をタイトルバー非表示の普通のウィンドウとしてピン留め
  できるようにした(M26。挙動仕様は §4.5)。最前面固定・全 Space 追従・位置記憶は
  「窓に居座られる」方向の性質としてすべて不採用
- **窓に ⌄ を置かない**: 毎日見続ける面に低頻度の操作(Rescan / Settings / Quit 等)が常駐して
  場所を取るのは不適切なため。操作の置き場所は「窓が存在する間だけ
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

- 一覧ウィンドウの実運用で、並び順まわりの分かりにくさの源が
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

- 大量のセッションを開いたときの見え方の検討から。従来は両方の器が
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

- §8.30 は最前面固定を不採用としたが、あれは**既定の挙動**としての判断だった(利用者が指定していないのに
  最前面に表示され続ける動作は、作業の妨げになる)。実運用で、並行作業が多い時間帯だけ最前面に表示する、という
  状況依存の需要が発生したため、**既定 OFF のトグル**として追加。
  ON にするのは利用者の明示的な操作なので、§8.30 の判断と矛盾しない
- 置き場所はアプリメニュー(Settings ウィンドウではなく)— 状況で切り替える性質の
  スイッチなので、窓を使っている最中に届く場所に置く。値は記憶する
- 変えるのはウィンドウレベル(floating)だけ。全 Space 追従は引き続き不採用(別種の押し付けがましさ
  なので混ぜない)
- **再検討の条件**: ON のまま忘れて他の作業の邪魔になる報告が繰り返されたとき
  (そのときは「窓を閉じたら OFF に戻す」等の自動リセットを検討)

### 8.34 Conversations(会話の一覧・検索・閲覧・再開)を追加した(M33–M35)

- §8.15 の再検討条件が成立: 「あの会話の続きをやりたいが、どのフォルダだったかを
  探して回る」が実運用で繰り返し発生。`claude -r` はディレクトリ単位でしか引けず、フォルダ横断の探索が
  欠けていた。形も §8.15 が予約したとおり「いまの状態ビューとは分けた別一覧から開き直す」(§4.6)
- **§8.17 の「transcript 解析はやらない」をこの機能に限り変更**: 「末尾を読みたい」「本文で検索したい」は
  hooks が運ばない情報で、transcript を読む以外に満たせない。
  読み取り専用・専用モジュールへの局所化・壊れるのは表示だけ・README に依存を明記、の条件で受け入れる。
  コスト表示をやらない判断(§8.17/§8.23)自体は不変。ベータ表記は付けない
  (依存の告知は README の一文で行い、看板にはしない)
- **名前は Conversations**: resume の付属機能として始まったが、設計の過程で
  「眺める・探す・読む」が resume と並ぶ独立の価値だと判明し、動詞(Search 等)ではなく対象物の
  名前にした。索引が持つのはセッションの記録から**会話(人の発話と Claude の返答)だけを抜き出したもの**
  なので、Sessions より Conversations が正確(`claude --help` 自身も "Resume a conversation by
  session ID" と、会話 = 中身 / session ID = 識別子の使い分けをしている)。Settings と Sessions の
  見間違い問題も同時に消えた。CLI(`conversations`)・DB ファイル名まで揃える。短縮エイリアスは
  実感が出たら足す
- 切り離しは構造で担保する: daemon・プロトコル・hooks・状態モデルは無変更。Rust 側の追加は
  CLI `resume`(§4.4)+ iterm モジュールの `open_resume_window`(§4.3)+ conversations モジュール
  (索引・検索。下記)
- **索引と検索は CLI(Rust)に置く**: 「スクリプトから会話を検索したい」が
  要件と宣言され、消費者が UI と CLI の 2 人になった(§8.2 の原則 — 実物 2 例が揃ってから境界を
  作る — のとおり)。当初はアプリ内(Swift)案だったが、Swift に置くと CLI 検索を後から足すコストが
  高い(再実装か私有スキーマの文書化)非対称があり Rust に決定。**境界は各コマンドの出力 JSON**で
  DB スキーマは私有(NDJSON プロトコルと同じ関係)。アプリはキー入力(デバウンス後)ごとに
  subprocess を起動して検索する — 起動 10〜30ms 程度で知覚できず、focus / reconcile と同じ作法。
  依存に rusqlite(libsqlite3-sys)を追加し、リンク先は macOS 同梱の libsqlite3(バンドルしない。§10)
- **索引は全会話 + live/past フラグ、ウィンドウも live を出す**:
  「過去だけの索引」はデータ層に UI の都合を焼き込む形で、live フラグ付きの全体を返し、絞るのは
  消費者の責任にする。名前から Past が消えた時点で「検索したのに実行中が出ない」は名前で説明できなく
  なり、ウィンドウにも live の行を出す(`running` の淡いテキスト印・アクションなし — Resume と
  別動詞の混在を作らない。実行中の会話への動詞は実感が出たら設計する)。
  終了時の一括抽出も生存中の逐次取り込みに分散して消える
- **search は「常に transcript の現在に対して答える」**: 検索という道具は
  結果の不在を信じられなければ意味がなく、「index を先に呼んだかどうかで結果が変わる」隠れ状態
  依存を作らない。DB は**アクセス時に自己更新される内部キャッシュ**と位置づけ、search は追いつきを
  内蔵する(`git status` が stat キャッシュを実行のたびロック付きで更新するのと同じ、実証済みの
  パターン)。追いつき中の他プロセスとは flock で調停し、**待つ**(黙って古い結果を返す経路を
  持たない)。全構築中だけは検索を提供しない(部分結果 + 不完全マーカーの機構は、マシンごとに
  一度きりの場面に対して過剰と判断)
- **live/past の判定は `~/.claude/sessions/` の pid ファイル**:
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
- **表示の更新はすべて利用者起点**: 開いたとき / 打鍵 / ⟳ ボタン / 自分の
  Resume 直後、の 4 契機のみ。「検索していないのに結果が変わる」驚きを作らない。当初案の FSEvents
  常時監視 → ウィンドウ表示中のみ → フォーカス時 refresh、と削っていき、search の自己追いつきが
  確定した時点で**監視そのものが不要**になった(索引の鮮度は表示の鮮度と無関係になったため)。
  daemon に監視を置く案も棄却(daemon はアプリと同じライフサイクル — §8.8 — で常駐性の利点が出ず、
  更新をアプリに伝えるプロトコル拡張が要り、壊れ得る transcript ドメインを中核に持ち込むため)。
  背景に残るのは索引の温め(起動時キック + 約 10 分ごと)だけで、これは速度の最適化であり
  正しさに関与しない
- **閲覧は全文一括 + 文書内ヒットナビゲーション**: 発話テキストは平均
  23KB・最大 280KB(§7-6 の実測から)で、選択時に全文を取得して遅延描画で出せる規模。
  当初の「末尾数往復 + 読み足しリンク」は resume 前の末尾確認が目的だった時代の設計で、
  「読む」が目的に昇格した時点で全文一括に置き換えた(範囲指定 API・読み足し状態・位置ずれの
  問題が一式消える)。複数ヒットは文書内検索の標準 UX(全ハイライト + カウンタ + ▲▼)で、
  初期位置は**最新のヒット**(検索の手がかりは最近の記憶であることが多く、同じ語なら終盤の方が
  結論に近い)。search 結果のスニペットは持たない(選択 = 即全文プレビューの世界では
  クリック前の選別の価値が薄い。再検討の条件: ヒットの選別でクリックの往復が苦になったとき —
  後から足すのは前方互換)
- **検索語は 2 文字から**: trigram は 3 文字未満を索引で引けないが、日本語は
  2 文字の語が普通に検索語になるため、2 文字の語は LIKE(唯一の LIKE 経路)で支える。1 文字の語は
  無視し、有効な語が無ければ検索しない(UI は発行せず、CLI は exit 1 — 黙って 0 件を返さない)。
  **再検討の条件**: 2 文字検索が体感で重くなったとき — 乗り換え先は格納時ビグラム化
  (手法実測済み — §7-6。スキーマ版の自動再構築で移行できる)。「3 文字に絞る」方向には直さない
- **複数語は AND**: 空白区切りの複数語は「全語を含む会話」に絞り込む。
  OR は語を足すほど結果が増え、インクリメンタル検索の「打つほど目当てに近づく」文法に
  逆行するため不採用。実装は語ごとに独立のクエリ(2 文字 = LIKE / 3 文字以上 = MATCH)で会話の
  集合を取りコードで積集合 — 語の長さの組み合わせによる場合分けを持たない。
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
  実行中セッションの resume を拒否しない(実機で確認)ため既存挙動への新しい入り口にすぎず、
  クリック時の再照合を足すコストと釣り合わない。§8.7・§8.12 と同じ「穴があっても平気な作り」の
  割り切り。**再検討の条件**: 二重 resume で実害(transcript の破損等)を実際に踏んだとき —
  そのとき `shiibar-cc resume` に実行前の照合(live なら拒否)を足す
- **機能全体の再検討の条件**: transcript のフォーマット変更による修理が繰り返し必要になったとき
  (Claude Code が公式のセッション一覧・履歴 API を出したらそちらへ乗り換える)。フレーズ検索・
  実行中の会話への動詞(Focus / fork)・スクロール記憶の永続化は実運用のシグナル待ち

### 8.35 Conversations ウィンドウを「読む画面」として再設計した(M36)

M35 の実機スモークで、見た目が読みにくい・畳みの中のヒットが見えない・
文字サイズを変更できない、という問題が判明し、右ペインを素のテキストの羅列から読む画面へ再設計した。
挙動仕様は §4.6、見た目の正は conversations-design.html。

- **自分の発言 = 全幅の帯、Claude の発言 = Markdown 描画**: この画面の主活動は「自分の短い指示 →
  Claude の長い返答」の繰り返しを読むこと。自分の発言は本文ではなく見出しとして全幅の帯
  (背景の明度差のみ・`❯` + 通常ウェイトの発言 — Claude Code のターミナル表示と同じ文法)にし、
  会話全体を「何を頼んだか」の目次として流し読みできるようにする。Claude の返答は元々 Markdown
  なので描画する — 素のテキスト表示が読みにくさの主因だった。役割ラベルの行(You / Claude)は
  帯と地の文の対比で不要になり廃止
- **棄却した右ペイン案**: 右寄せバブル(技術的な長文で左右往復が読みにくい)/
  帯への色付け — 琥珀のアクセント(色面は不要。無彩の明度差で足りる)/
  太字の見出し(帯が見出しの仕事をするので文字を強めない)/ Claude 側のインデント
  (帯だけで区別が足りる)/ 全文モノスペース切り替え(Markdown 描画でコードが常にモノスペースに
  なり実需が消えた — 残る需要が出たら §8.10 と同じ「実害が出たら足す」扱い)
- **一覧の行は「時刻を 1 行目の右端」**(Messages / Mail の文法)+ ホバーのハイライト。罫線・
  ゼブラ・時間のグループ見出し(Today 等)は棄却 — 現代の会話リストの主流は罫線を引かず、
  区切りは行の内部構造とホバーで読ませる。時間見出しは行ごとの経過時間表示と情報が重複するので不要
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

M36 の実機スモークで、1 つの指示に Claude の発言が連発すると境目が読めないことが判明した。
索引は自動 wake-up・ツール実行を除外するため、エージェントが長く走ったセッションでは
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
生のパイプ記号は壊れて見えることが実機で判明した。

- **パイプ表をネイティブのグリッドで描画する**(ヘッダ強調・行間罫線・左揃え・セル内インライン有効・
  内容幅 + 横スクロール。§4.6)。等幅整形(列幅を空白で揃えてコードブロックの器に載せる)案は棄却 —
  モノスペースフォントに日本語グリフが無く、フォールバックした CJK の幅が揃わないので列が崩れる。
  セル内のインラインも効かず、整形用の空白が描画後テキスト(検索対象)に混ざる
- **Markdown 描画ライブラリは採らず、自前のブロック分解を続ける**:
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

M36〜M38 の SwiftUI 描画には、本文の表示と操作の問題が複数あり
(メッセージをまたぐ選択ができない・インライン code に padding が付けられない・行間が狭い・
表のセルが折り返さない・Markdown でコピーできない)、うち 2 つ(またぎ選択・インライン padding)は
SwiftUI の `Text` では構造的に不可能だった。HTML 描画を検討し、
スパイクで実証してから採用を決めた。

- **右ペインのメッセージ面だけを WKWebView にする**(§4.6)。システム WebKit なので追加依存は
  ゼロ(§10 は無傷)。ヘッダ・検索バー行・Resume・一覧・Settings はネイティブのまま
- §8.5(Tauri ではなく SwiftUI)とは矛盾しない: あの決定の前提「webview を描く場面がない」は
  メニューバー UI の話で、Conversations で「文書を読む面」が生まれた時点でこの面には
  当てはまらなくなった。アプリの器・通知・常駐は native のまま
- **スパイクの実証**(実データ最大 415 メッセージ・描画後 147k 文字): 初回表示 584ms(温まり
  ~367ms)・打鍵ごとのハイライト再描画 64〜69ms・WebContent プロセス約 100MB(窓の存在中のみ)。
  問題 5 件は合計 10 行程度の CSS で解消。`<script>` 入りの会話が文字として表示されることを確認
- **意味論は Core が正のまま**: ヒット・畳み・バッジは M36〜38 の計算(テストで固定済み)を
  ページに渡し、JS では再計算しない。境界のオフセットは Core の書記素数から UTF-16 に変換して渡す
  (JS 文字列は UTF-16 — 絵文字で全ハイライトがずれるのをスパイクで検出・解決済み)
- **セキュリティ規律**(依存を持ち込んだ側の責務): 本文は textContent 経由のみ / nonce 付き CSP /
  ナビゲーション全キャンセル(リンクは既定ブラウザ)/ 非永続データストア
- **採用に対する反論も記録する**: +100MB のプロセスと、自分で持ち込んだ分のセキュリティ面、
  `swift test` の外の JS 層を、本文の表示と操作の小さな問題 5 件のために足すのか — という見方はあり得た。
  採らなかった理由: この画面の主活動が「読む」であり、問題が本文の表示と操作に集中し続けたこと、
  5 件中 2 件は native では構造的に直らないこと、見た目の正(conversations-design.html)と
  実装の乖離が構造的に消えること
- コピーの当初の文法: 右クリック = **Copy(⌘C)/ Copy as Markdown(⇧⌘C)** の 2 項目。
  「表示どおり」と「原文」の 2 動詞で、選択なしの Copy as Markdown はカーソル下のメッセージ
  (実機スモークで手直し — 下記。現行の文法は §4.6)
- **実機スモークからの手直し**: (1) メニューの Copy は **WebKit 標準の
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
  ペーストボードまでの端到端テストを必須にする(検証点は (6) で改めた)。合わせてメニューは
  **Copy / Copy as Markdown の 2 項目のみ**に(Look Up 等の標準項目は取り除く —
  読む画面に置く動詞を 2 つに絞る)。
  (6) 3 巡目: (5) の「ペーストボードの中身まで検証」の縛りが**機能を削っていた** —
  WebKit の `copy:` は本物のクリップボードにしか書けないため、テスト可能性を優先して
  自前のプレーンテキスト専用経路が作られ、リッチテキストが落ちた。
  主従を正す: **機能が先、テストは機能に従う**。
  ⌘C は WebKit の `copy:` を呼ぶだけに戻し(書式込みのコピーがそのまま手に入る・自前経路を
  持たない)、テストの検証点は「キーが `copy:` に届くこと」までに改める — 呼び出し先の
  フレームワークを再テストしない。⇧⌘C(自前機能)の中身検証は従来どおり。
  合わせて**選択なしのコピーを全廃**(カーソル下メッセージの原文コピーを削除 —
  「選択していなければ何もコピーできない」の方が説明不要)。メニューは常に 2 項目・
  選択なしは両方 disabled(1 巡目の disabled 事故の真因は Edit メニュー不在であり、
  disabled 項目自体は無害)
  (7) 4 巡目: 検索バー行の ▲▼(裸の山形 2 つ + `2/5`)は、押せることと向きの意味を
  判別しにくい — **macOS 標準の文書内検索の文法**(`N of M` + ‹ › セグメンテッド + ⌘G / ⇧⌘G)に
  寄せる(§4.6)。ヒット 1 件だと再スクロールしない実装も判明し「押下のたびに現在ヒットへ
  スクロール」を仕様に明記。合わせて**サイドバー幅を境界ドラッグで可変**に
  (初期 250pt・200〜400pt・幅を記憶 — §9。固定幅は初期値に格下げ)
  (8) 5 巡目: 検索バーのセグメンテッドコントロールがペイン全幅に伸びる事故 —
  「コントロールは内容サイズ・左寄せ」を明文化。‹ › は端で折り返す(⌘G の慣習)。
  ヘッダ下の区切り線は検索バーの有無によらず常時。running の会話で下部パネルごと消していたのを
  「常に出して Resume を disabled + 理由の一言」に(§8.34 の「アクションなし」の趣旨 —
  動詞を増やさない — はそのままで、表示の形だけ変更 — パネルが消えるとレイアウトが跳ねて分かりにくいため)。
  ⟳ は押下の反応を必ず見せる(実行中 disabled + `Refreshing…`)。サイドバー境界は
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
  実際の AppDelegate 構築連鎖を組み立てる回帰テスト。**起動生存チェックの自動化は
  見送り** — 起動の確認は、所有者の実機スモークの役割
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

開くと一番下(最新)から始まることが画面から読み取れない、という問題から出発し、
VS Code の全体図をこの画面向けに翻案して採用した。

- **略図方式**: 縮小テキスト(VS Code 方式)は DOM 複製が要り最大級の会話で重い。描画に使っている
  ブロック構造と実レイアウト座標から矩形を描くだけの略図にする(詳細は不要)。
  帯 = 濃い縞が「会話の目次」として全体図に見える
- **スクロールバーと合体**: ミニマップを OS スクロールバーの左に並べる案は「つまみ」と「現在範囲」の
  二重表示になるため棄却。ミニマップ自体をスクロールバーにする(VS Code と同じ) —
  半透明グレーの帯がつまみ(当初の青い枠は棄却)、右ペイン内の OS スクロールバーは非表示
- **常時表示・幅 20pt**(14 / 20 / 26 の試作を比較して選択)。ヒット分布の目盛り(§8.35)は
  ミニマップ上の線として吸収
- **下端の手がかり**: 終端マーカー(`Latest message · <経過時間> ago`)+ 上端のスクロールシャドウ。
  「↑ N earlier messages」のフローティングピル案は棄却(数秒で消える = 常設の手がかりにならない)
- **計装ログの整理**: 真っ白問題(§8.38(9))の解決後、正常系の毎回のログ(送信・ack)は削除し、
  異常系(保留からの放流・自己修復・再注入・プロセス死・JS エラー)だけを既定レベルで残す —
  §8.38(9) の教訓「異常が自分で名乗るログ」の形
- **タイポグラフィは見た目の正に一致させる**: 実装は行間と余白が狭く、読みにくいことが実機で判明 —
  行間・段落間・ブロック間隔・帯の余白は conversations-design.html の CSS 値が正で、
  実装側の目視合わせではなく値の一致で担保する。Resume ボタンのサイズも同様

### 8.40 メニュー再編: 窓の動詞の島と Agents の名前(M39)

Conversations ウィンドウの追加でメニューの文法が崩れていた:
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
テキスト入力が存在しなかった。Conversations の検索欄で ⌘V と ⌘A が動作しないことが実機で判明
— macOS の標準ショートカットは**メニュー項目の key equivalent 経由で
配達される**ため、Edit メニューを消したアプリでは全テキスト欄で死ぬ(WebView の ⌘C —
§8.38(5) — と同じ穴のテキスト欄版)。

- **Edit メニュー(標準項目のみ)を復活**: Undo / Redo / Cut / Copy / Paste / Select All。
  項目は標準のレスポンダチェーン任せ(自前ハンドラを持たない)。File / Format / View /
  Window / Help は引き続き出さない — 「消せるものは消す」の趣旨は保ち、実用に必要な 1 本だけ戻す
- Edit メニューを追加した状態で使用して判断する — 使用感に問題があれば §8.30 の形へ戻して
  ウィンドウ側のキー処理で個別に配達する案(WebView の ⌘C と同じ方式)に切り替える

### 8.42 ボタンは自分で反応する(⟳・Resume)。Edit の注入項目は抑止 2 つ + 受け入れ 2 つ(M39)

- **⟳ の「反応がない」は 3 巡目で正しく直った**: 1 巡目(実行中 disabled + `Refreshing…`)も
  2 巡目(完了後 `Updated` 2 秒)もステータス行の文字を直していたが、不足していたのは
  ボタン自体の押下の反応だった(1 巡目の disabled 化は数十 ms で終わって知覚できず、
  装飾なしスタイルにはホバーも押下も無い)。
  ボタンに状態を持たせる(ホバー / 押下 / 実行中は矢印回転 + disabled)。矢印回転は
  リロードボタンの標準文法で、working のグリフ循環スピナー(✻)とは別物 — menubar-design.html が
  working に予約しているのは「グリフ循環スピナー(·✢✳✶✻✽)」であり、単一グリフの回転とは
  別文法なので衝突しない。教訓: 「反応」はまず操作した部品自身が返す
- **Resume の disabled は標準の灰色の器**: prominent のまま淡くなる
  標準の見た目は「押せそうな色のまま押せない」で中途半端。ボタンなしで理由だけの案は
  「ボタンがいつもの場所にある」一貫性を失うため棄却。通常状態にもホバー・押下を付ける
- **Edit メニューのシステム注入項目**: Start Dictation・Emoji & Symbols は標準の抑止設定で
  消せた(実機で確認)。**Delete と AutoFill は受け入れる** —
  実際にメニューを開いて観測した結果、SwiftUI がメニューを所有し開くたびに作り直すため、
  隠しても消しても戻る(公認の抑止設定も存在しない)。完全除去には標準グループを自前項目に
  置き換える工事が要り、有効/無効の自動管理を失うリスクと釣り合わない。どちらも macOS 標準の
  項目で大半のアプリの Edit に出るもの

### 8.43 窓の動詞は「開くか、前面に出す」。⟳ は最低 1 回転(M39)

- **Agents… / Conversations… は窓が既にあるとき disabled にせず、押したらその窓を最前面に
  出す**。従来の disabled 規約(M26 以来)は「前面化は Dock / ⌘Tab の
  仕事」という分担だったが、メニューを開いた指がそのまま窓に届く方が自然で、macOS の
  Window メニューの標準文法(開く/切り替えの同居)とも一致する。Agents 窓の
  「位置は毎回アイコン直下」規則は新規に開くときだけ働く(前面化では動かさない)
- **⟳ は実行が一瞬でも最低 1 回転してから戻る**(§9): 検索は数十 ms で終わり、状態を作っても
  一瞬すぎて知覚できなかった。「見える反応」には最低の可視時間が要る

### 8.44 ⟳ の回転は真上から整数回転・静止時は背景なし。Text size はポップアップ(M39)

- **⟳ の回転は必ず真上から始まり、回転の切れ目で終える**: 回転角を
  壁時計時刻から導出していたため開始位相が押した瞬間しだいで毎回任意になり、終了時も途中の
  角度から真上へ瞬間的に飛んでいた(押すたびに違う位置から始まり、1.25 周して止まる動作を
  実機で確認した)。位相をリフレッシュ開始時刻基準に変え、実行が終わっても回転の
  切れ目(整数回転)まで回り切ってから止める — 開始・終了とも真上で揃い、静止形への飛びは
  角度ゼロになって消える。最低 1 回転(§8.43)はこの規則に包含される。周期は 0.8 秒 → 0.6 秒
  (0.8 秒は遅く感じるため)
- **⟳ の静止時は背景なし・ホバーでグレーの地**: 静止時の常時グレー地が
  disabled Resume の「標準の灰色の器」(§8.42)とほぼ同じ見た目で、同じ窓の中で「グレーの
  ピル」が押せる/押せないの反対の意味を同居させていた。Finder / Safari のツールバーボタンと
  同じ「ホバーでだけ地が出る」文法に変え、常時グレー = 押せない、に意味を一本化する
- **Text size はステッパーをやめ、音種と同じポップアップ**: ステッパーの
  矢印は的が小さすぎて、プレビューを見ながら何度も押す操作に向かない。ポップアップなら
  一操作で狙った値に飛べて、Settings 内の他のコントロール(Appearance・音種 2 つ)とも部品が
  揃う。範囲は 11〜18pt → 10〜20pt に広げる(既定 13pt は不変)

### 8.45 Conversations 窓の初期サイズは 1050×700(M39 後)

- 640×480 → **1050×700**: 640×480 はサイドバー 250pt を引くと本文が
  約 370pt しか残らず、2 ペインの読み物ウィンドウとしては窮屈。実機で実寸を段階的に
  試して(1200×800 / 1100×700 / 1080×700 / 1050×700)決めた。行長は 60em で頭打ちのため、
  この幅でも本文が間延びしない

### 8.46 開いたときは最新の会話を自動選択(M39 後)

- **窓を開いて選択が無ければ、最初に一覧が出た時点で先頭(最新)を自動選択する**:
  従来は「Select a conversation」のプレースホルダで、開くたびに
  必ず 1 クリック要った。この窓を開く動機はほぼ「最近の会話を見る/探す」で、show は
  1 回で全文が来る軽い動詞(§8.34)なので、最新を最初から見せる。一覧 + プレビュー窓の
  macOS の標準文法(Mail など)とも一致
- **自動選択の契機は「開いたとき」だけ**: 打鍵・⟳ で選択中の会話が結果から消えたときは
  プレビューをクリアするだけで、別の会話を選び直さない(§4.6)。検索中に選んでいない
  本文が勝手に出る驚きを作らない(§8.34 の思想)

### 8.47 Terminal.app に対応する(§8.11 の範囲拡張・§8.2 の「2 例目」成立)(M40)

- 契機は Terminal.app を使う実利用者の出現。§8.11 と §8.2 が予約していた
  再検討条件「2 つ目のターミナルに実際に対応する PR を書くとき」がこれで成立した。
  §8.11 の判断自体(飛べないセッションを追跡しない)は変えない — 「飛べるターミナル」の集合が
  iTerm2 のみ → iTerm2 + Terminal.app に広がっただけで、対応外を drop する規則・フォールバック
  target を作らない規則はそのまま
- **どのターミナルの利用者かはセッションごとに env で自動判定**し、モード設定は持たない:
  設定方式は「設定は iTerm2 のままなのに Terminal.app で起動した」という切り分けにくい不一致故障を
  新設するだけで、判定コードは 1 バイトも減らない。1 台 1 ターミナルを前提にするが、
  混在利用も判定上は自然に成立する(作り込み・テストはしない)
- **target は全種 prefix つき**(`iterm2:` / `apple-terminal:`。§2)に変えた。「無印 = iTerm2」の
  暗黙ルールを永久に背負わないため。prefix はターミナル名フルネームの小文字ハイフン —
  数文字の略語は不採用(人間が手打ちする場面が無く、対応表を要求する分だけ損。
  `apple-terminal` は `TERM_PROGRAM` の実値 `Apple_Terminal` に寄せた)
- **Terminal.app の識別子は tty**(§7-7): `TERM_SESSION_ID`(UUID)は存在するが AppleScript 側に
  対応物が無く、「中と外の両方から見える鍵」が tty しかない。tty はタブを閉じると再利用され得る
  弱い鍵だが、**誤ジャンプは focus 失敗と同等に扱って許容する**(reconcile の掃除が前提。
  過剰な防御は作らない)。**再検討の条件**: 再利用による誤ジャンプを実際に踏んで気になったとき —
  そのとき focus 前に tab の `processes`(タブ内のプロセス名リスト)に `claude` が含まれるかの
  安全弁を足す(プロパティが辞書に存在することは確認済み(§7-7)。実行時の中身は導入時に実測する)
- **Resume のターミナルは観測追随**(§4.6): 初回起動時に質問しない(アプリは答えを観測で
  知っているし、保存した答えは乗り換えで陳腐化する)。明示制御が欲しくなったら Settings に
  1 項目足す(困った実感が出てから)。CLI `resume` だけは `--terminal` を持つ(§4.4) —
  resume は daemon 非接続の原則(§8.15 の削除後に Conversations で再導入した形)を保つため、
  観測データを持つアプリが決めて引数で渡す
- **doctor / reconcile は起動中のターミナルにしか AppleScript を投げない**: iTerm2 だけの利用者に
  Terminal.app への TCC プロンプトを一切見せない(逆も同じ)ことが受け入れ条件
- **スモークは所有者が Terminal.app 経路も自分で行う**
- **3 つ目以降のターミナル**は同じ手順で 1 件ずつ: 実利用者が現れたら、「中からセッションを特定できる
  env + 外からそのセッションに飛べる手段」のペアが成立するかをスパイクで確認してから対応を決める
  (kitty / WezTerm 等は AppleScript ではなく独自 CLI になる見込みで、統合作業は毎回 1 セット丸ごと)。
  ターミナルモジュールの共通インターフェース化は 3 例目の実物を見てから(§8.2 の原則を維持)

### 8.48 running の会話のボタンは Jump — disabled の行き止まりを無くす(M41)

- 契機は §8.34 が予約していた再検討条件「実行中の会話への動詞は実感が出たら設計する」の成立。
  Conversations で会話を探し当てて running だと分かった瞬間に
  したいことは「そこへ行く」— 目的地は特定できているのに disabled で突き当たり、
  メニューバーの一覧から探し直すのは二度手間
- **ボタンの意味を「この会話の続きをやる」に捉え直す**: past なら Resume(新しいウィンドウで再開)、
  running なら **Jump**(動いている画面へ移動)。2 つの動作は同じ意図の 2 つの顔で、
  行の状態がどちらの顔かを決める
- **ラベルは Jump**: この製品の中核動詞(README "jump straight to the right one")と同語。
  Go to / Show in Terminal は棄却 — 長いだけで意味が増えず、製品内の語彙も割れる
- **disabled が残るのは「live だが Agents 一覧に一致が無い」行だけ**: live 判定(pid ファイル)と
  daemon の追跡は独立なので、対応外ターミナル(VS Code のターミナル・SSH 等)で動く会話は
  running 印つきで一覧に載るが飛び先が無い。ボタンは Jump のまま灰色にし、注記
  `Running in a terminal Shiibar CC can't drive` で理由を言う(動詞を変えない —
  「うまくいかないときだけ現れる別の動詞」を作らない)
- **注記は Jump でも残す**(`This conversation is running`): ボタンだけだと
  「なぜ Resume でないのか」が読めない。ツールチップは持たない — 注記が既に理由を言っている
- **Resume と Jump は同幅固定**(長い方 = Resume に揃える): 下部パネルは常設で、行を移るたびに
  ボタンが替わる。幅がラベル任せだと端が毎回動き、連打時に狙い直しになる。
  §8.42 の「高さ不変」の横方向版
- **ボタン状態の導出は選択時と一覧配達時だけ**: Agents 一覧は subscribe でライブに変わるが、
  それに追随して表示中のボタンが勝手に Jump ⇄ disabled と入れ替わるのは §8.34
  (表示が変わるのは利用者が動かしたときだけ)に反する。ズレの結果は押したときの focus が
  そのまま報告する(該当なし = exit 2)— この画面の live 印と同じ「鮮度は主張しない」文法
- **Jump 成功後に search を再実行しない**: Resume 後の再実行は「past → running に変わる」ためだが、
  Jump は会話の状態を何も変えない。変わっていないのに一覧を触らない(§8.34)
- **事前チェックは持たない**: 行き先の有無を一番正確に知っているのはターミナル本体で、
  focus の全走査そのものが確認になっている。daemon エントリや pid での事前確認は代理情報のうえ、
  確認と実行の間にタブが閉じる競合が残り、「claude は終了したがタブは残っている」ケースへの
  有用な着地(最終出力を見る・その場で開き直す)を潰す。「entry が消えていてもタブが生きて
  いれば飛べる」という focus の既存の立場(§4.4)をそのまま引き継ぐ
- **該当なしの Jump はシートで知らせ、更新は利用者が選ぶ**: この画面の表示は利用者起点でしか
  更新されない(§8.34)ため、「running 表示のまま実体は終了」のズレは次の ⟳・打鍵まで
  残り続ける。ドロップダウンの行クリックの該当なしが無言で許されるのは、あちらの一覧が
  subscribe でライブに再生成されて古い行が長生きしないからで、この画面に同じ理屈は効かない。
  無言にはしない・かといって勝手に一覧を更新しない(押した操作と起きることの因果が読めない)
  — 標準の NSAlert シート([Cancel] [Refresh]・既定 Refresh)で事情を言い、更新するかを
  利用者に選ばせる。棄却案 2 つ: 失敗を契機にした search の自動再実行(利用者起点の原則には
  適うが、一覧が勝手に組み替わる体感になる)/ ボタン左隣の注記の差し替え(気づけるが、
  次の一手 = 更新への導線がない)。シートの見た目は標準のまま(アプリアイコンつき —
  独自の形を作らない)

### 8.49 一覧を 1 つに統合し、ポップオーバーとウィンドウで同じレイアウトを表示する

- 契機: 実運用で最も多い操作は「Conversations で過去の会話を検索して Resume する」
  だった。実行中のセッションの一覧(ドロップダウン / Agents ウィンドウ)と会話の一覧
  (Conversations ウィンドウ)は別の画面にあり、同じ会話が状態によって別の場所に表示されていた。
  §8.48 で running の会話に Jump を追加した時点で、2 つの一覧は「同じ一覧の行の状態違い」に近づいていた
- **画面はポップオーバーとウィンドウの 2 つ、レイアウトは 1 種類**: Agents ウィンドウと
  Conversations ウィンドウは、このウィンドウに統合した。ポップオーバーは OS 標準の `NSPopover` で、
  ウィンドウは `Open in window` で開く。画面ごとにレイアウトを設計すると、検索欄の文字や選択の扱いを
  画面ごとに決める必要があり、片方でしか実行できない操作が生じる。レイアウトを 1 種類にすれば、
  状態(検索欄の文字・選択・表示中のページ)を 1 つにして、2 つの画面で共有できる。
  棄却案:
  - ウィンドウだけにして、トレイアイコンのクリックでウィンドウの表示と非表示を切り替える案 —
    採用しなかった。メニューバーのアイコンから開く画面として、ポップオーバーを残した
  - ポップオーバーは 1 列だけ、ウィンドウは 2 列だけ、と画面ごとに形を固定する案 —
    ウィンドウを細くして使用できなくなる
  - ポップオーバーの中で会話の全文を一覧の隣に表示し、ポップオーバーを横に広げる案 —
    OS 標準のポップオーバーは矢印の位置を中心に広がるので、広がるときに一覧が左右に移動する。
    一覧を固定するには矢印のない自前のパネルが必要になり、アイコンの位置によっては全文が一覧の左に
    表示される(他のアプリに例の無い動作で、違和感がある)
- **幅で 1 列と 2 列を切り替える**: 通常は一覧だけで足り、検索して内容を
  確認するときに全文が必要になる。1 列では、一覧のページと詳細ページをスライドで切り替える。
  幅がしきい値(§9)以上のウィンドウでは、一覧と全文を 2 列で同時に表示するので、検索結果を順に
  確認するときにページの往復が不要になる
- **行のクリックは選択、実行は下部パネルのボタン、詳細ページは行の `>` ボタン**(実装後の実機確認で変更):
  当初は、どの行にも Jump / Resume と Branch のアイコンボタンを常に表示し、
  1 列では行のクリックで詳細ページを開いた。実機では次の問題があった。
  (1) 1 列では、マウスで行を選択する手段が無い(クリックすると詳細ページに移動する)。
  (2) すべての行にボタンが 2 つずつ並び、行の文字より目立つ。
  (3) 行をクリックするつもりでボタンを押すと、ターミナルのウィンドウが開く。
  変更後は、行のクリックは 1 列でも 2 列でも選択だけになり、実行のボタンは、選択中の行を対象にする
  1 組だけを下部パネルに表示する。一覧のページと詳細ページで、ボタンの位置と見た目が同じになる。
  マウスでの Resume は「行のクリック → 下部パネルのボタン」の 2 クリックになる
  (行をクリックした後の Enter でも実行できる)。
  **選択中の行をもう一度クリックすると、選択を解除する**: 選択なしの状態に、マウスで戻れる。
  解除するのは、青で表示している行をクリックしたときだけである。灰色の行のクリックは、一覧を操作対象に戻す
  操作なので、選択を保持する(実機確認で変更)。
  **行のダブルクリックは Jump / Resume を実行する**: 一覧にフォーカスがある間の Enter と
  同じ動作を、マウスの 1 操作で実行できる。詳細ページを開く動作にしなかった理由は、2 列では選択した時点で
  右の列に詳細を表示していて、ダブルクリックの動作が無くなるためである。
  ダブルクリックはクリックとは別の操作なので、青の行のクリックによる選択の解除は、ダブルクリックでないことが
  確定するまで実行しない(解除の反映が、システムのダブルクリックの間隔だけ遅くなる)。
  マウスのボタンを押した時点で解除し、ダブルクリックだった場合に再び選択する案は、ダブルクリックの途中で
  選択の表示が消えるので採用しなかった。
  棄却案:
  - 選択中の行とホバー中の行にアイコンボタンを表示する案 — 同じ操作のボタンが、2 つの行に同時に
    表示される
  - 行のクリックに実行を割り当てる案 — 列の数でクリックの結果が変化するか、Jump に 2 手必要になるかの
    どちらかになった
- **キーの割り当て**(実装後の実機確認で変更): Enter は Jump または Resume、
  ⌘Enter は Branch、→ / ← は 1 列での詳細ページの開閉、↑ / ↓ は行の移動、Esc はポップオーバーを
  閉じる操作である。キーの動作は、検索欄にフォーカスがある間と、一覧にフォーカスがある間で分ける。
  検索欄では文字の編集だけを行い、検索欄の Enter で一覧にフォーカスを移す。行の操作のキー
  (↑ / ↓、Enter、⌘Enter、→ / ←)は、一覧にフォーカスがある間だけ有効である。
  選択中のカードは、キーの操作対象が一覧である間は青、検索欄にフォーカスがある間と、ウィンドウが key で
  ない間は灰色で表示する(色を変えないと、一覧にフォーカスがあるかどうかが分かりにくい。macOS の標準の一覧と
  同じ表現にした)。
  **1 列の詳細ページの ↑ / ↓ は会話のスクロールで、前後の会話への切り替えは ⌥↑ / ⌥↓ である**: 当初は
  ↑ / ↓ で会話を切り替えたが、文章を表示している画面の ↑ / ↓ はスクロールが標準で、一覧が表示されていない
  状態で行を移動する動作には違和感があった。2 列では一覧が表示されているので、↑ / ↓ は行の移動である。
  検索欄での ↑ / ↓ による行の移動と、一覧での文字の入力による検索欄への移動は、実装して実機で確認した後に
  廃止した(検索欄と一覧の境界が分かりにくいため)。一覧から検索欄に戻る操作は、⌘F と検索欄のクリックである。
  当初は、フォーカスの位置で動作を分けず、Enter を詳細ページの開閉、⌘Enter を Jump または Resume、
  ⇧⌘Enter を Branch に割り当てた。その時点では、Enter を実行にする案は「検索の確定のつもりで押した
  Enter で Resume が実行される」、→ / ← を詳細ページの開閉にする案は「検索欄のカーソルの移動と衝突する」
  という理由で採用しなかった。フォーカスの位置で動作を分けると、この 2 つの問題は発生しない。
  Enter で実行する割り当ては他のアプリと共通で、実機では当初の割り当てより直感的だった。
  **選択なしの間の検索欄の Enter は、先頭の行を選択する**: フォーカスを移すだけでは、画面上の変化が
  検索欄のカーソルの消失だけになる。検索文字列の変更による自動の選択(下記の棄却案)とは異なり、
  利用者が Enter を押したときだけ選択する。「入力 → Enter → Enter」で、先頭の会話を Resume できる。
  **実行のキーは下部パネルのボタンの中に表示する**: 当初は、キーの案内に `⌘↩ Resume` を表示し、
  同じ行の右に `Resume` のボタンがあって、同じ内容を 2 回表示していた。Branch のキーは、
  画面のどこにも表示していなかった。
  会話内のヒットの移動は、macOS の文書内検索の標準である ⌘G / ⇧⌘G のままにした。
  棄却案:
  - Space、Tab を詳細ページの開閉に割り当てる案 — Space は検索欄の文字の入力、Tab はフォーカスの移動と
    衝突する
  - ポップオーバーを開いたときに検索欄の文字を全選択する案 — 検索を続けるときに、最初の打鍵で
    文字が消える
  - 一覧のページでの Esc を「1 回目は検索欄を空にし、2 回目で閉じる」にする案 — Esc の動作が
    検索欄の内容で変化する
  - 会話内だけを別の文字列で検索する機能(⌘F を会話内検索にする案)— 一覧の検索文字列が
    そのまま会話内のヒットになるので、必要になるまで追加しない
- **Running と History の 2 区画。Waiting / Working / Idle の見出しは廃止**(§8.25 / §8.31 の Grouped と
  Sort by を置き換え): 更新順の 1 本の一覧では、開いたまま操作していないセッションが過去の会話の間に
  埋もれる。区画があれば実行中のセッションは必ず上にまとまり、行が区画をまたぐのは開始と終了のときだけに
  なる。状態の見出しは、記号で判別できるので不要
- **行は 3 行のカード**: 3 行目に、その会話で最後に自分が送った発話を表示する。タイトルは
  会話の最初の時点で決まることが多く、長い会話では、最後の発話のほうが「どこまで進めたか」を
  思い出す手がかりになる。Running の行も 3 行にそろえた。検索中も 3 行目は最後の発話のままにする
  (ヒットの抜粋に差し替えると、同じ行の内容が検索文字列で変化する)。
  行をカードにして、選択中のカードを淡い青の地と枠で示す(選択色の塗りと白文字にすると、
  状態記号・赤バッジ・スターの色が選択中の行で判別しにくくなる)。
  棄却案: History をカードにして自分の発話を並べ、発話ごとに返答を展開する案(操作が難しいため)
- **会話の発言に `You` / `Claude` のラベルを付ける**(§8.35 の「ラベル行を配置しない」と §8.36 の ⏺ マーカーを
  置き換え): 自分の発言の `❯` と Claude の発言の ⏺ は、ラベルに置き換えた。自分の発言の帯の地は残した。
  幅 420pt のポップオーバーでは帯と本文の幅の差が小さく、記号だけでは発言者を判別しにくい
- **詳細ページの Resume と Branch は、下部の文字付きのボタン**(見出しにアイコンボタンで
  配置する案と比較して選択した): 見出しには、戻るボタン・位置・前後の移動をすでに配置している。
  下部パネルの注記(§8.48 の `This conversation is running` など)は廃止した。同じ行の左にキーの案内を
  配置するので、注記の場所が無い。disabled の Jump の理由は、ボタンのツールチップで示す
- **ステータス行は廃止し、フッターはキーの案内にした**: 会話の件数は区画の見出しが示す。索引の進捗・
  エラー・一時表示は、表示する内容があるときだけメッセージ行に表示する
- **行を選択するのは利用者の操作だけで、選択なしの状態がある**(§8.46 の自動選択は廃止):
  起動後は選択なしで、選択中の行が一覧から無くなったときも選択なしにする。Jump / Resume / Branch の
  対象は、利用者が自分で選択した行だけになる。
  棄却案:
  - 行がある間は常に 1 行を選択し、選択中の行が無くなったら先頭の行に移動する案 —
    利用者が確認していない行が ⌘Enter の対象になる
  - 検索文字列を変更するたびに先頭の結果を選択する案 — 「入力 → ⌘Enter」で Resume できるが、
    選択が自動で移動する場面が残る。「入力 → ↓ → ⌘Enter」の 1 打鍵の差なので採用しなかった
- **ポップオーバーの高さは変更でき、記憶する**: 下端のドラッグで変更する。
  Settings に高さの項目は追加しない(大きさは、表示している画面で直接変更できれば足りる)。
  高さを変更した後で初回の高さに戻したくなる場面のために、ドラッグ中に初回の高さで固定する。
  ⌄ メニューに初回の大きさへ戻す項目を追加する案は、この動作があれば不要なので
  採用しなかった。ウィンドウのリサイズには、固定する動作を追加しない。
  幅は固定のままにした。OS 標準のポップオーバーは矢印の位置を中心に左右へ広がるので、
  幅を変更すると一覧が左右に移動する。高さは下端だけが移動する
- **この決定が置き換える過去の決定**: §8.30 の「ウィンドウに ⌄ を配置しない」と「位置を記憶しない」
  (ウィンドウの見出し行に ⌄ を配置し、位置と大きさを記憶する)/ §8.32 の「一時的な画面の大きさは
  内容が決め、リサイズは無い」(ポップオーバーは固定の幅と、変更できる高さを持つ)と
  「ウィンドウは縦だけリサイズでき、幅は固定」(縦横にリサイズできる)/ §8.33 の
  「Keep on Top の配置場所はアプリメニュー」(見出し行のピンのボタンにした。アプリメニューの項目は無い)/
  §8.40 の Agents… と Conversations… のメニュー項目と、アプリメニューの Agents の見出し
  (ウィンドウが 1 つになったので無い)/
  §8.45 のウィンドウの初回の大きさ(§9 の値にした)/ §8.48 の「ボタン状態の導出は選択時と一覧配達時だけ」
  (Running の行の増減時にも導出する)
- **History に表示する行に上限を設定**: 全件を表示しても、検索の結果を
  すべて表示しても、下のほうの行は確認しない。探している会話が上限の中に無いときは、検索で絞り込む。
  表示していない会話の数を末尾に表示する(表示が無いと、会話が存在しないのか、表示していないのかを
  判別できない)。「さらに表示」の操作は追加しない。CLI の search にページングや件数の制限は
  追加しない(アプリは結果の全体を使用する。会話は取得の間にも追加・更新されるので、ページの間で
  行の重複や欠落が発生する)
- **Branch を追加**(§8.34 が実運用のシグナル待ちとしていた fork): 過去の会話にも実行中の会話にも
  実行できる。CLI は `resume --fork`(§4.4)
- **スター**: History の中で繰り返し使用する会話を上に固定する。保存先は UserDefaults(§4.6)
- **色**: 赤は未確認、黄はスターだけに使用する。青(アクセントカラー)は、選択・`You` のラベル・
  ピンの ON・主ボタン・テキストボタンに使用する。状態(waiting / working / idle)は引き続き色を使用しない
- **見た目の仕様は `docs/window-design.html` にまとめた**: Conversations ウィンドウの見た目の仕様
  (`docs/conversations-design.html`)を置き換えた。メッセージ面の CSS 値を実装の正とする規則(§8.39)は、
  `docs/window-design.html` に引き継ぐ
- **History を再取得する契機を追加**(§8.34 の「表示の更新はすべて利用者起点」を変更): ウィンドウが
  key になったときと、Running の行が消えたとき。ウィンドウを表示したままにする使用では、
  従来の 4 契機だけでは「会話したのに一覧に現れない」状態が ⟳ を押すまで続いた。
  Running の行が消えたときの再取得が無いと、終了した会話がどちらの区画にも表示されない時間が生じる。
  FSEvents の監視を持たない判断は変更しない
- **一覧にヒットの抜粋・件数を表示しない**(§8.34 の判断を維持): 会話ペインがヒット位置を表示する。
  抜粋は行の高さを増やし、一度に表示できる結果を減らす。件数は、CLI が生テキストで検索した結果と、
  会話ペインが描画後テキストで数える値(§4.6)が一致しないため表示しない
- **running の会話の該当なしシート(§8.48)は廃止**: Jump を表示するのは daemon が追跡している行だけに
  なり、その行は subscribe で最新に保たれる。古い live 印に基づく Jump が無くなった
- **採用しなかったもの**:
  - 会話のリネーム — Claude Code の会話名を外部から変更する文書化された手段が無い(`-n` は起動時、
    `/rename` はセッション内、選択画面の Ctrl+R のみ。Claude Code 2.1.323 の `--help` と
    公式ドキュメントで確認)
  - 保存期間(`cleanupPeriodDays`)の表示と変更 — プロジェクト側の設定ファイルにも同じキーを記述できる
    ため、1 つの値を表示すると、実際に適用される値と一致しない場合がある。`~/.claude/settings.json` を
    このアプリが書き換えることもしない
  - usage の表示 — プランの使用率を取得できるのは statusline の入力だけで、§8.23 の棄却理由が
    そのまま該当する
  - フルスクリーンのアプリの上への表示 — 要件にしない
- **再検討の条件**: 会話内で、一覧の検索文字列とは別の文字列を検索したい場面が繰り返し生じたとき →
  会話内検索を検討する。スター付きの会話が保存期間で削除される事例が実際に起きたとき →
  削除前の通知を検討する

### 8.50 グローバルホットキーを追加した

- **決定**: 利用者が登録したキーの組み合わせで、ポップオーバーを開閉する
  (ウィンドウを開いている間は、ウィンドウを前面に移す)。§4.5「グローバルホットキー」。
- **理由**: ターミナルで作業している状態から、マウスを使用せずに一覧を開いて Jump できる。
  一覧を開く操作は、トレイアイコンのクリックだけだった。
- **開いたときのフォーカスは一覧にする**: ホットキーで開く目的は、行を選択して Jump または Resume を
  実行することであり、開いた直後に ↑ / ↓ と Enter を使用できる。検索する場合は ⌘F を押す。
  トレイアイコンのクリックで開いたときのフォーカスは、検索欄のままである。
- **キーの組み合わせは利用者が登録する。初期状態は未登録にする**: 固定の組み合わせは、
  他のアプリのショートカットと衝突した場合に、利用者が回避できない。
  ⇧ を含む任意の修飾キーの組み合わせを登録できる。
- **`RegisterEventHotKey` を使用する**: `NSEvent` のグローバルモニターは、アクセシビリティの権限が必要で、
  押したキーが前面のアプリにも届く。
- **確認した動作**(2026-11-16、macOS 27.2.1): 登録、解除、同じプロセスでの二重登録の拒否
  (`eventHotKeyExistsErr`)を確認した。別のプロセスが登録している組み合わせの登録は、拒否されなかった。
- **再検討の条件**: `RegisterEventHotKey` が、対象の macOS で動作しなくなったとき

### 8.51 トレイアイコンの working を静止画にした

- **決定**: トレイアイコンの working は、静止した `✻` の下に 3 つの点を並べた画像で表示する。
  アニメーションのタイマーは使用しない。一覧の行の working は、グリフ循環スピナーのままである(§4.5)。
  §8.29 のうち、トレイの working をグリフ循環スピナーで表示する部分を上書きする。§8.42 が参照する
  「working のグリフ循環スピナー」は、一覧の行の記号(window-design.html)だけになる。
- **理由**: トレイアイコンの画像を設定するたびに、AppKit がメニューバーの表示をメインスレッドで
  作成し直す(`-[NSStatusItem _updateReplicants]`)。この処理時間は画像の内容に関係なく一定で、
  CPU の使用率は画像を変更する回数に比例する。working のセッションがある間の使用率の計測結果
  (2026-11-17、macOS 27.2.1、`ps` と `top` で計測。処理の内訳は `sample` で確認):
  グリフ 6 種類・周期 2 秒(2 秒に 10 回の変更)= 約 14% / グリフ 3 種類・周期 4 秒(4 秒に 4 回の変更)=
  約 3% / 静止画 = 約 0.1%。エージェントが動作している時間は長いので、その間の使用率を優先した。
- **内容が同じ画像を設定しない**: 同じ計測で、画像の内容が変化していないときにも画像を設定すると、
  画像の設定と外観の監視からの再設定が繰り返され、使用率が約 91% になることを確認した。
  設定の前に内容の変化を判定する(§4.5)。
- **図柄の選択**: 3 つの点は、処理中を表す記号として一般に使用されている。idle(`✻` だけ)と
  形が違うので、濃度の差に依存せずに区別できる。
- **採用しなかった案**:
  - グリフの種類を減らし、周期を長くしたスピナー — 使用率は約 3% まで下がるが、0 にはならない。
  - `✻` を太いグリフ `✽` に入れ替える — idle との差が、グリフの太さと濃度だけになる。
  - 窓を塗りつぶし、`✻` を抜き文字にする — waiting(線の窓と `!`)よりも目立ち、優先度の順序と
    目立つ順序が逆になる。
  - `✻` の下に、長さの違う線を 2 本描く — 実機で確認し、採用しなかった。
  - 3 つの点の配置の違い(`✻` の右に並べる / `✻` を表示せず中央に並べる / 濃度を段階的に変える)—
    図で比較し、採用しなかった。
- **再検討の条件**: トレイアイコンの画像を変更したときの AppKit の処理時間が、アニメーションを
  表示しても使用率が 1% 未満になる程度まで短くなったとき。

### 8.52 文字の大きさの設定を、ポップオーバーとウィンドウの全体に適用する

- **決定**: Settings の Text size を、会話ペインの本文だけの設定から、ポップオーバーとウィンドウの全体の
  設定に変更する(§4.5「文字の大きさ」)。値は本文の文字の大きさ(pt)の整数で、範囲は 9〜18、既定は 13 である。
  ほかの文字、行の高さ、上下の余白、アイコン、ポップオーバーの幅は、13 に対する比率で連動する。
- **理由**: 文字の大きさの設定は会話ペインの本文だけに適用され、一覧、見出し行、下部パネルの文字の
  大きさは変更できなかった。
- **比率で連動する寸法と固定の寸法を分ける**: 文字の大きさに合わせて必要になるのは、行の高さと上下の余白と
  アイコンである。左右の余白、角の半径、枠線の太さは、文字の大きさを変更しても同じ値で表示できるので、
  固定にする。OS が描画する部品(信号機ボタン、標準のセグメント)は、大きさを変更できない。
- **ポップオーバーの幅を連動させる**: 幅を固定にすると、文字を大きくしたときに 1 行に表示できる文字数が
  減り、行の 1 行目と 2 行目で、末尾が省略される範囲が増える。ウィンドウは、利用者が大きさを決めているので変更しない。
- **既定の 13 は、変更の前の表示と同じである**。変更の前に保存した値(会話ペインの本文の大きさ)は、
  そのまま新しい設定の値として使用する(範囲の外の 19 と 20 は 18 として扱う)。
- **Settings の操作部品は、数値の入力欄とステッパー**: 入力欄は 1 回の入力で値を指定でき、
  ステッパーは 1 ずつ調整できる。
- **この決定が変更する過去の決定**: §8.35 の「Settings の Conversations 節」(Text size は General に配置し、
  Conversations 節は無い)/ §8.44 の「Text size はポップアップ」と「範囲 10〜20pt」/ §8.49 の
  「ポップオーバーの幅は固定」(幅は文字の大きさに連動する。ドラッグで変更できないことは同じである。
  OS 標準のポップオーバーは矢印の位置を中心に広がるので、文字の大きさを変更したときは、一覧が左右に移動する)。
- **再検討の条件**: 一覧と会話ペインで、別の文字の大きさを指定する必要が生じたとき。

### 8.53 2 列の一覧の列の幅を、境界のドラッグで変更できるようにした

- **決定**: ウィンドウの 2 列の表示で、列の境界をドラッグして、一覧の列の幅を変更できる。変更した幅は
  記憶する。境界のダブルクリックで、既定の幅に戻す(§4.5「幅による切り替え」)。
- **理由**: 一覧の列の幅は文字の大きさだけで決まり、利用者が直接変更できなかった。
- **記憶した幅は、文字の大きさより優先する**: 利用者が指定した幅なので、文字の大きさを変更しても
  変更しない(ウィンドウの大きさと同じ扱い。§8.52)。
- **2 列になる幅は、既定の幅から計算する**: 記憶した幅から計算すると、一覧の列を広げた後に、
  2 列で表示できるウィンドウの幅でも 1 列になる。
- **再検討の条件**: ポップオーバーの幅も変更する必要が生じたとき。

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
| report の tty 祖先 walk 上限 | 10 段(上限まで制御端末が見つからなければ drop。§4.1) | 固定 |
| last_assistant_message の切り詰め | 先頭 200 文字   | 固定                     |
| Rescan 結果の一時表示        | 2 秒                 | 固定                     |
| 一覧の行の working スピナーの周期 | 2 秒(グリフ循環 `·✢✳✶✻✽`・コサインイージング・50ms 刻み) | 固定(本家 TUI の実測値) |
| ポップオーバーの大きさ       | 幅 420pt(文字の大きさ 13 のとき。比率で連動する — §4.5「文字の大きさ」)。高さは初回 640pt・最小 300pt・最大はディスプレイの可視領域に収まる高さ。記憶した高さが最大を超えるときは、最大の高さで表示する(記憶した値は変更しない) | 高さだけリサイズ・記憶 |
| ポップオーバーの下端のドラッグ領域 | 高さ 8pt(カーソルは上下リサイズの形) | 固定 |
| Running の行が消えた後の 2 回目の再取得 | 2 秒後 | 固定 |
| History に表示する行の上限   | 100 行(Running の区画には適用しない) | 固定 |
| ポップオーバーの高さを初回の高さに固定する範囲 | 初回の高さの前後 12pt 以内(ドラッグ中だけ) | 固定 |
| ウィンドウの大きさ           | 初回 420×640pt・最小 360×300pt。縦横リサイズ可・位置と大きさを記憶 | リサイズ |
| 2 列になる幅                 | 一覧の列の既定の幅 + 460pt 以上(文字の大きさ 13 のとき 880pt。未満は 1 列。§4.5) | 文字の大きさに連動 |
| 一覧の列の幅(2 列のとき)   | 既定 420pt(文字の大きさ 13 のとき。比率で連動する)。最小 280pt、最大はウィンドウの幅から右の列の最小の幅を引いた幅。ウィンドウの幅を変更しても変化しない(右の列の最小の幅を確保できない場合を除く。§4.5) | 列の境界のドラッグ・記憶(ダブルクリックで既定に戻す) |
| 右の列の最小の幅(2 列のとき) | 460pt(列の境界の線の 1pt を含む) | 固定 |
| 列の境界のドラッグ領域       | 幅 8pt(境界の線の中心から左右 4pt ずつ。カーソルは左右リサイズの形) | 固定 |
| ページの切り替えのスライド   | 0.22 秒(ease-in-out) | 固定                     |
| 経過時間の再取得             | 60 秒(ポップオーバーまたはウィンドウの表示中のみ) | 固定 |
| wait の既定タイムアウト      | なし(無限待ち)       | `--timeout`              |
| 会話ペインのミニマップ      | 幅 20pt・本文はミニマップ手前 8pt で折り返す(挙動は §4.6) | 固定 |
| ⟳ の結果表示                | `Updated · N conversations` を 2 秒(Rescan の一時表示と同値) | 固定 |
| ⟳ の回転                    | 周期 0.6 秒・最低 1 回転(開始・停止の規律は §4.6) | 固定 |
| 発言コピーの反応             | アイコンをチェックマークに 2 秒(Rescan の一時表示と同値。§4.6) | 固定 |
| 文字の大きさ(Text size)   | 既定 13pt・範囲 9〜18pt の整数(§4.5「文字の大きさ」。⌘= / ⌘− / ⌘0) | Settings ウィンドウ / ⌘ ショートカット |
| メッセージの畳み             | 先頭 500 文字(描画後テキスト)を超えたら畳む(`Show full message` / `Show less`。DB は全文) | 固定 |
| UI 検索のデバウンス          | 200ms(`conversations search` の subprocess 起動前) | 固定 |
| 検索語                       | 2 文字から(1 文字の語は無視)・語数上限なし(照合規則は §4.6) | 固定 |
| SQLite ロック待ち(busy timeout) | 5 秒(明示設定 — §4.6) | 固定 |
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
