# shiibar-cc 設計書

> menu bar agent status & jump for Claude Code + iTerm2 / Terminal.app / Ghostty

## 1. 目的

Claude Code のエージェント状態(working / waiting / idle と、未確認フラグ。§3)を macOS メニューバーで
常時可視化し、通知や、ポップオーバーとウィンドウの一覧(§4.5)から該当する
対応ターミナル(iTerm2 / Terminal.app / Ghostty)のタブへジャンプできるようにする。
対応ターミナル以外のターミナルで実行しているセッションも、状態の表示と通知の対象にする(ジャンプだけができない。§8.66)。
ターミナルを持たないセッション(制御端末を持つ祖先のプロセスが無いセッション。エディタの拡張機能、常駐プロセスが起動する実行など)は追跡しない(§4.1)。
対話でない方法で起動したセッション(`claude -p`)は、追跡せず、会話の一覧にも表示しない(§4.1・§4.6・§8.67)。
同じ一覧で過去の会話を検索して読み、再開・分岐できる(§4.6)。
CLI(`shiibar-cc`)は hooks とアプリをつなぐ**裏方**(report / focus / reconcile / resume / conversations / doctor)であり、
利用者向けの表面はメニューバーと通知に集約する(`wait` / `watch` などのスクリプト利用も可能だが主役ではない)。

### 設計原則

1. **特化する**: Claude Code 専用。タブへのジャンプと、Resume / Branch のウィンドウを開く操作は、
   対応ターミナル(iTerm2 / Terminal.app / Ghostty。§8.47・§8.66)だけで実行する。speculative generality は書かない
2. **意味の局所化**: 外部依存(ターミナルの ID 形式、AppleScript)を知るコードは `shiibar-cc-client` の
   ターミナルモジュール(iterm2 / apple_terminal / ghostty)に閉じ込める。抽象化レイヤーは作らないが、汚染も広げない
3. **メニューバーは読み取り + focus のみ**: 破壊的・対話的な操作はすべて CLI に置く
4. **表示クライアントは全部 subscriber**: daemon に対して対等。増減してもコアに手が入らない

### 非スコープ(作らないもの)

- tmux 対応(通常モードも -CC も)
- Claude Code 以外のエージェント対応
- サイドバー TUI / iTerm2 Toolbelt
- worktree の作成・削除統合(作成はユーザーのシェル関数で足りる)
- リモート / SSH 対応(接続先のホストで実行しているセッション。接続先の hook は、このマシンの daemon の socket に報告を送れない)
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

- **target は prefix つきの不透明文字列**(`<prefix>:<セッション識別子>`)。対応ターミナルの 3 種類と、
  それ以外のセッションの 1 種類である:
  - `iterm2:<UUID>` — UUID は `$ITERM_SESSION_ID` の `:` 以降。位置プレフィックス `wNtNpN` は**含めない** —
    hooks(report)と reconcile(iterm2_targets)が同一セッションに**同じ target を導出できる**ことが
    突き合わせ(§3.5)の前提で、AppleScript からは wNtNpN を再現できない(§7-1)ため
  - `apple-terminal:<tty パス>` — 例 `apple-terminal:/dev/ttys006`。Terminal.app では tty が
    「中(hook の環境)と外(AppleScript)の両方から同一セッションに導出できる」唯一の鍵(§7-7。
    `TERM_SESSION_ID` は AppleScript 側に対応物が無く使えない)
  - `ghostty:<tty パス>` — 例 `ghostty:/dev/ttys005`。Ghostty でも、中と外の両方から導出できる鍵は tty である
    (§7-8。`GHOSTTY_SURFACE_ID` は、AppleScript の `id` と一致しないので使えない)。対象は Ghostty 1.4.0 以上(§9)
  - `process:<pid>` — 例 `process:48213`。対応ターミナルの target を導出できないセッション(VS Code のターミナル、
    そのほかのターミナル、1.4.0 未満の Ghostty など)。鍵は、そのセッションを実行している `claude` のプロセスの pid である
    (hook では、制御端末を持つ最初の祖先のプロセス — §4.1。reconcile では、`claude agents` の一覧の pid — §3.5)。
    **この target のセッションは、タブへジャンプできない**(状態の表示、未確認、通知は、ほかの target と同じである。§8.66)。
    `process` はターミナルの名前ではなく、鍵の種類を表す
  - 対応ターミナルの prefix は**ターミナル名フルネームの小文字ハイフン**(略語にしない — 人間が手打ちする場面が無く、
    自己記述性だけが価値。§8.47)。ターミナルが増えたら同じ規則で 1 種類ずつ増える
  - **ジャンプできるかどうかは、prefix で決まる**: `iterm2:` / `apple-terminal:` / `ghostty:` はジャンプできる。
    `process:` と、クライアントが知らない prefix は、ジャンプできない(§4.2「プロトコル契約」)
  - shiibar-ccd は解釈せず保持・転送するだけ。意味を知るのは shiibar-cc-client の
    ターミナルモジュール(iterm2 / apple_terminal / ghostty)と、target を生成する `shiibar-cc report` と reconcile の gather のみ。
    例外は、次のとおりである: アプリは、prefix でジャンプできるかどうかを判定する(§4.2「プロトコル契約」)。
    `shiibar-cc report` は、環境変数で target の種類を判定する(§4.1)。アプリは、Resume と Branch を開くターミナルが使用できるかどうかを、
    バンドル ID とバージョンで判定する(§4.5「Settings ウィンドウ」)。daemon は、`process:` を含めて、どの prefix も見分けない
    (§3.6「pid による統合」は、target の文字列の一致と `pid` だけで判定する)
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

| status    | 意味                         | 表示(トレイ / 一覧の行の状態記号)                |
| --------- | ---------------------------- | ---------------------------------------- |
| `working` | 実行中(あなたの番ではない)   | 紋章 `✻` と 3 つの点(静止)/ グリフ循環スピナー |
| `waiting` | 許可・入力待ち(あなたの番)   | 紋章スロットに太い `!` / 輪郭の吹き出し + `!`(オレンジ) |
| `idle`    | 待機中                       | 静止 `✻`・全体 0.8 / 薄い `✻`(静止)    |

**状態を示す色は 2 つである: オレンジ = waiting(あなたの操作を待って止まっている)、アクセントカラー = unreviewed(まだ確認していない — §3.2)**。working と idle には色を使用しない。オレンジは、waiting である間は、確認済みかどうかに関係なく表示し、waiting でなくなった時点で消える。アクセントカラーの点は、unreviewed フラグと同じ時点で付き、同じ時点で消える。色を使用する場所は、一覧の行の状態記号と点(§4.5「Running の行」)、閉じている Running の印(§4.5「区画の開閉」)、トレイアイコンの点(§4.5「見た目の正」)である(アプリアイコンの点は固定の色 — §9。§8.65)。見た目の正は、トレイアイコンが menubar-design.html、一覧の行が window-design.html。

### 3.2 unreviewed フラグ

「そのセッションが**あなたの番の状態(`waiting`、または完了直後の `idle`)に入ってから、まだ確認していない**」
ことを表す(確認にあたる操作は、§4.5「未確認を下ろす操作」)。**`waiting` と `idle` にのみ乗る**(`working` はあなたの番ではないので持たない)。

| status + flag           | 意味                                                 |
| ----------------------- | ---------------------------------------------------- |
| `waiting` + unreviewed  | 新しい許可待ち、未確認 ← **最重要アラート**            |
| `waiting`(確認済)       | 許可待ちだが、既に確認した(対応中)                   |
| `idle` + unreviewed     | 完了して結果を未確認                                  |
| `idle`(確認済)          | 見た/そもそも何もしていない(静か)                   |

set / clear の規則 — **hook イベントは §3.4 の表の flag 列に従う(status が同値でも適用する。表が正)**。
reconcile は status の遷移で決まる(§3.5):

- **立てる**: Notification(waiting 系。既に `waiting` でも、新しい要求が届いた事実を優先して立て直す)
  / 完了の Stop(background_tasks 空。既に `idle` でも立て直す)
  / reconcile: `waiting` へ遷移したとき、未追跡セッションを `idle`・`waiting` で新発見したとき(§3.5)
- **下ろす**: 確認した(= seen。focus の成功、アプリの一覧で利用者が選択した行の、選択の継続、`Mark all as read` — §4.5)/ `working` にする hook(UserPromptSubmit、PostToolUse の waiting 解除、
  Stop・background_tasks 残)/ SessionStart(新規開始)/ reconcile: `working` へ遷移したとき
- **触らない**: reconcile が status 不変を再確認したとき(既に立っている `waiting` を再確認しても保持)。
  reconcile で `waiting` → `idle` へ遷移したときも**保持**する(まだ見ていない事実は変わらない。
  新たに立てもしない。§3.5)

「あなたの番(新しい要求・完了)が届いたら立ち、見た/動き出したら下りる」が要点: hook を取りこぼして
reconcile で `waiting` への遷移に気づいた場合も、未確認として通知される。

### 3.3 status の source(2 つ)

- **hooks(リアルタイム push・主軸)**: イベントを受けて即座に status を更新(§3.4)
- **`claude agents --json`(reconcile)**: アプリ起動時・daemon 再接続時・定期(約 1 分。§4.5/§9)・Refresh(§4.6)で実行(§3.5)。
  Claude 自身の権威ある一覧を **status の正**として突き合わせ、daemon 不在中の取りこぼしを直す backstop。
  claude agents の status(4 値)は shiibar の status に `busy` / `shell` → working、`waiting` → waiting、
  `idle` → idle と対応する

hooks が主でリアルタイム。reconcile はイベントを取りこぼした隙間を埋める。両者は普段一致し、
食い違うのは daemon が誤っているとき(取りこぼし / §8.7 の誤解除)だけなので、その場合は常に claude agents を正とする。

### 3.4 hook イベント → status 遷移(テスト仕様)

「—」は status 変更なし(hook 由来の行は last_seen だけは更新する — §3.6。**seen 行は
last_seen も更新しない** — §4.2)。「登録」列は未登録 target の新規作成。
**ターミナルで実行しているセッションを、すべて追跡する**: 対応ターミナルの target を導出できたセッション(§4.1 の 3 分岐)は、その target で、
導出できないセッションは `process:<pid>` で登録する(§2・§8.66)。**この表は、target の種類に関係なく、
同じ遷移を適用する**。制御端末を持つ祖先が無い report(ターミナルを持たないセッション)は drop する(§4.1)。
**SessionEnd だけは、制御端末を持つ祖先が無い場合も、`target` を持たない report として送る**(ターミナルのウィンドウを閉じて終了したセッションは、
SessionEnd の時点で制御端末を持たない — §7-12)。daemon は、`session_id` が一致するエントリを削除する(§3.6「`target` を持たない SessionEnd」。
表の SessionEnd の行と同じ結果である。未登録の列の「無視」も同じで、一致するエントリが無い場合は、何もしない)。
1 つのセッションを 2 つの target で登録しない規則は §3.6「pid による統合」。**表の「未登録」の列と状態の列は、
§3.6「pid による統合」の「hook の report」で、適用するエントリを決めた後の状態で読む**(target が未登録でも、pid が同じエントリがあれば、
そのエントリの状態の列を適用する)。**入れ子のセッションの report は、この表を適用する前に無視する**
(実行中のセッションが起動した別の `claude` のプロセスの report。§3.6「入れ子のセッション」)。

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
| seen(focus 成功時に client が送る。アプリが送る時点は §4.5「未確認を下ろす操作」。§4.4)   | 無視          | —       | —       | —       | 下ろす       |

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
   `apple-terminal:<tty パス>`(§7-7。`ps` の tty は `/dev/` 無しなので前置して正規化する)、
   Ghostty の terminal の tty に一致すれば `ghostty:<tty パス>`(§7-8。正規化は同じ)。
   **tty を持ち、どの走査にも一致しないセッションは、`process:<pid>` で送る**(対応ターミナル以外で実行しているセッション。§8.66)。
   ターミナルのウィンドウを閉じた直後の、終了の途中のセッションも、この条件に該当する(ウィンドウを閉じてから SessionEnd の hook までの約 3.5〜5.5 秒の間、
   `claude` のプロセスは tty を持ったまま動作し、ターミナルの走査には無い — §7-12)。この間に走査が完全な回があると、エントリは `process:<pid>` に付け替わり
   (§3.6「pid による統合」)、その後の SessionEnd が、`session_id` の一致で削除する(§3.6「`target` を持たない SessionEnd」)。
   `ps` の出力に無い pid(`claude agents` の実行の後に終了したプロセス)と、tty を持たない pid(ターミナルを持たないセッション。
   実行中のセッションの Bash ツールが起動した `claude -p` のプロセスも、tty を持たない — §7-9)は、送らない。
   **対話でない方法で起動したセッションの pid も、送らない**: `claude agents` の一覧は、`claude -p` のプロセスも `kind` が `interactive` のセッションとして返す(§7-13)。
   pid ごとに、Claude Code の `~/.claude/sessions/<pid>.json` の `entrypoint` を読み取り、値が `sdk-cli` の pid を除外する(§8.67。
   このファイルを読み取る処理は、live/past の判定と同じく、`crates/shiibar-cc` の会話のモジュールに配置し、client には、pid から値を返す処理として渡す — §4.6)。
   ファイルが無い、読み取れない、JSON として解釈できない、`entrypoint` が無い、値が `sdk-cli` 以外の場合は、除外しない。
   どのセッションにも、`claude agents` の一覧の pid を付けて送る(§4.2 の `pid`)。
   ただし、**試みた走査のいずれかが失敗/不完全なときは、どの走査にも一致しないセッションを、更新専用(§4.2 の `update_only`)として送る**
   (target は、完全な回と同じ `process:<pid>` である)
   (走査が取りこぼした対応ターミナルのセッションを、`process:` の target で二重に登録しないため。daemon は、更新専用のセッションでは、
   登録済みのエントリの更新だけを行い、エントリの作成と target の付け替えを行わない — §3.6「pid による統合」)。
   **1 つのターミナルの走査の失敗(オートメーションの権限の拒否を含む)は、ほかのターミナルの走査と、その結果の送信を止めない**
   (失敗したターミナルは、その回の走査を不完全にするだけである。権限の拒否があった回は、送信の後に exit 3 で終了する — §4.4)。
   未起動のターミナルには AppleScript を投げない(is-running 照会は起動を誘発しない。§7-7)—
   未起動 = そのターミナルのセッションは存在しないので、空の走査結果と同じ扱いでよい。
   **試みた走査のいずれかが失敗/不完全なとき(-1719 等。§7-1)は、その回は prune を行わない**(生存確認できないものを消さない。
   client は `complete:false` を付けて送り、daemon は prune だけを省いて add / update は行う。§4.2)。
   **`ps` の実行が失敗した回(実行のエラー、または 0 以外の終了コード)も、走査が不完全な回として扱う**: ターミナルの走査の結果に関係なく、
   `complete:false` で送る(起動中のターミナルが無く、どのターミナルの走査も完全である回を含む)。この回は、`process:<pid>` のセッションを送らない
   (どの pid が tty を持つかを確認できないため)。ターミナルの走査で一致したセッションは、送る。
   tty を確認できなかったセッションを、prune で削除しないためである
2. **status をマップ**(client 側): `busy` / `shell` → working、`waiting` → waiting、`idle` → idle。
   **未知の status 値は working とみなす**(セッションを live 一覧から落とすと prune で生きたエントリを
   消しかねない。追跡を維持し、flag は立てない)

daemon は受け取った live 一覧(target / status / cwd / session_id / waitingFor)を **claude agents を正として**適用する:

3. **突き合わせ(キー = target。適用する順序と、pid が同じエントリの target の付け替えは §3.6「pid による統合」の「reconcile」)**:
   - 未追跡 → **追加**。`idle` / `waiting` なら unreviewed を立てる(新発見 = あなたが未確認)
   - 既知 → status を反映(claude agents が常に勝つ。時刻での調停はしない。§3.3)。
     status が **`waiting` へ遷移したら unreviewed を立て、`working` へ遷移したら下ろす**(§3.2)。
     既知セッションが `idle` へ遷移した場合は立てない(完了は claude agents から判別できない。§8.12)が、
     `waiting` → `idle` で**既に立っている flag は保持**する(まだ見ていない事実は変わらない。§3.2)。
     status が不変なら flag は触らず、`last_seen` を更新する(生きたエントリを stale sweep で消さないため)。
     `waiting` の場合は `message` を `waitingFor`(ワイヤ上は `waiting_for`。§4.2)で更新する
   - **prune**: 走査が成功し、かつ claude agents の live 集合に無い target を削除し `agent_removed` を配信
     (その回のセッションをすべて適用し、target の付け替えを終えた後のエントリで判定する)。
     `process:` のエントリも、同じ規則で削除する(`claude agents` の一覧から無くなった時点で、終了とみなす)

reconcile は Claude 自身の権威ある登録簿を正とするので、「居ない = 本当に死んでいる」が信頼でき、
生きた `waiting` を誤って消すことはない(必ず一覧に載る)。`waiting` へ遷移すれば unreviewed を立てるので、
**daemon 不在中に許可待ちになったセッション(既知・未追跡どちらも)をここで拾える**。
唯一復元できないのは完了直後の unreviewed だけ(claude agents は完了を `idle` としか見せない。§8.12)。

### 3.6 エントリの属性と削除

- 属性: `target`(プライマリキー)/ `status` / `unreviewed` / `session_id` / `cwd`
  / `pid`(そのセッションを実行している `claude` のプロセスの pid。report と reconcile が運ぶ値で、適用するたびに上書きする。
  受け取った内容に `pid` が無い場合は、エントリの `pid` を変更しない。
  **`state.json` には保存しない**: daemon の起動の直後は、どのエントリも「不明」で、次の report または reconcile が設定する。
  daemon が停止している間に、プロセスが終了して pid が再利用される場合(マシンの再起動を含む)があるので、保存した pid を根拠にしない)
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
- **`process:` のエントリ**: 鍵は `claude` のプロセスの pid である。上書き規則は、対応ターミナルの target と同じである
  (同一 target で `session_id` が変わると、`session_id` と `cwd` を上書きする — §7-4)。ただし、`process:<pid>` の target の report は、
  常に、その pid を持つので、`session_id` が変わる report は、下記「入れ子のセッション」の判定の対象になる:
  上書きするのは、`source` が `clear` または `resume` の SessionStart と、エントリの `pid` が不明の間(daemon の起動の後)の report、reconcile による上書きだけである。`/clear` は、対応ターミナルの target と同じ経過になる:
  SessionEnd がエントリを削除し、続く SessionStart が、同じ target で再登録する(§7-3。pid が同じなので、target は変化しない。`created_at` は新しくなる)。
  セッションの中での resume も、同じ target のままである。同じ `session_id` を、2 つのプロセスが resume している場合は、2 つのエントリになる。
  実行中のセッションが起動した別の `claude` のプロセスの report は、親と同じ pid を持つので、下記「入れ子のセッション」の規則で無視する
- **pid による統合**(1 つのセッションを、2 つの target で登録しない。§8.66): hook と reconcile は、別の方法で target を導出するので、
  同じプロセスのセッションに、異なる target を導出する場合がある(hook は環境変数で、reconcile はターミナルの走査で判定する)。
  原則は 1 つである: **エントリの target を決めるのは、走査が完全な回の reconcile である。hook の report は、エントリの target を変更しない**。
  「pid が同じエントリ」は、`pid` が不明でなく、受け取った内容の `pid` と同じ値のエントリである(受け取った内容に `pid` が無い場合は、該当なしとする)。
  pid が同じエントリが複数ある場合は、`last_seen` が最も新しいエントリを対象にする(`last_seen` が同じ場合は、`created_at` が新しいエントリ)
  - **hook の report**(target T、pid P): 適用するエントリを、次の順で決める。(a) target が T のエントリがあれば、そのエントリ。
    (b) 無ければ、pid が P と同じエントリ(target は T と異なる。エントリの target は変更しない)。(c) どちらも無ければ、未登録として、
    §3.4 の「未登録」の列を適用する(登録する場合の target は T)。(a) または (b) でエントリを決めた場合は、下記「入れ子のセッション」の判定を行い、
    無視しない report だけを適用する。決めたエントリに §3.4 の遷移を適用し、`pid` を P にする。
    **SessionEnd も、同じ順で決めたエントリだけを削除する**(reason は `session_end`)。`target` を持たない SessionEnd は、
    この順ではなく、`session_id` で決める(下記「`target` を持たない SessionEnd」)
  - **reconcile(走査が完全な回)**: 次の順で適用する(結果が、セッションの並びの順に依存しないようにするため)。
    1. target が登録済みのエントリに一致するセッションを、すべて適用する(§3.5 の 3 の「既知」。`pid` を上書きする)。
    2. 残りのセッション(target T が未登録。pid P)を、1 件ずつ適用する。pid が P と同じで、**target がこの回の live 集合に無い**エントリ
       (複数ある場合は、その中で `last_seen` が最も新しいもの。同じ場合は `created_at` が新しいもの)があるときは、そのエントリの target を T に付け替える(下記「付け替え」)。
       その後、「既知」として適用する。
       該当するエントリが無いときは、「未追跡」として追加する(§3.5 の 3)。
    3. prune を実行する(§3.5 の 3)。

    2 は、どちらの向きにも同じ規則である: `process:<pid>` で登録したセッションの tty を、ターミナルの走査が見つければ、対応ターミナルの target に付け替える。
    対応ターミナルの target で登録したセッションの tty を、完全な走査が見つけなければ(環境変数の相続などで、hook が誤って導出した target — §7-1・§7-8)、
    `process:<pid>` に付け替える(その行は、ジャンプできない行になる)
  - **reconcile(走査が不完全な回)の更新専用のセッション**(§3.5): 適用するエントリを、hook の report の (a)、(b) と同じ順で決め、
    §3.5 の 3 の「既知」の規則をそのまま適用する(status、unreviewed、`message`、`since`、`last_seen`。`session_id` と `cwd` も上書きする)。
    該当するエントリが無ければ、何も実行しない。エントリの作成、target の付け替え、prune は実行しない。
    daemon は、更新専用のセッションを、`complete` の値に関係なく、この規則で適用する(client は、更新専用のセッションを、走査が不完全な回にだけ送る)
  - **reconcile(走査が不完全な回)の、更新専用でないセッション**(成功した走査に一致したセッション。target T、pid P): target が T のエントリがあれば、
    「既知」として適用する。無くて、pid が P と同じエントリがあれば、そのエントリに「既知」を適用する(target は付け替えない。エントリは作成しない)。
    どちらも無ければ、「未追跡」として追加する(§3.5 の 3)。prune は実行しない。
    **適用する順序は、走査が完全な回と同じである**: target が登録済みのエントリに一致するセッションを、すべて先に適用し、その後に、残りのセッション
    (更新専用のセッションを含む)を 1 件ずつ適用する
  - **付け替え**: エントリの `target` だけを変更する。ほかの属性(`status` / `unreviewed` / `since` / `created_at` / `task` / `message` /
    `last_assistant_message` / `last_report_at` / `session_id` / `cwd` / `pid`)は、そのまま引き継ぐ。配信は、`agent_removed`
    (古い target。reason は `rekey`、`to` は新しい target — §4.2)と、その**直後**の、新しい target の `status_changed` である
    (引き継いだ内容に変化が無い場合も配信する — 購読しているクライアントが、そのセッションを失わないようにするため。
    この `status_changed` は、付け替えの後の「既知」の適用を反映した内容で、そのセッションについて、その回に配信する唯一の `status_changed` である。
    1 回の reconcile の配信をまとめて送る場合も、この 2 つを隣り合わせて、この順で送る)
  - **統合で、エントリを削除することは無い**: エントリが無くなるのは、下記の削除経路だけである。pid が同じエントリが、2 つの対応ターミナルの target で
    登録されている場合も、統合しない。走査に無い側は、完全な回の prune が削除する
  - `pid` が不明のエントリ(daemon の起動の後、最初の report または reconcile を受け取る前)は、target だけで突き合わせる
- **入れ子のセッション**(実行中のセッションが起動した、別の `claude` のプロセスの report を、親のエントリに適用しない。§8.66):
  `claude -p` の report は、hook が送らない(§4.1・§8.67)ので、下記の判定の対象になるのは、hook が drop しない report だけである
  (`CLAUDE_CODE_ENTRYPOINT` が `sdk-cli` 以外の値である子のプロセス)。この規則は、その report に適用する。
  実行中のセッションが、制御端末を持たない子の `claude` のプロセスを起動すると、子の hook の祖先 walk は、親の `claude` のプロセスに到達する。
  子の report(SessionStart / UserPromptSubmit / Stop / SessionEnd など)は、親と同じ pid、同じ tty、同じ環境変数(`ITERM_SESSION_ID` を含む)から導出した、
  親と同じ target を持ち、`session_id` だけが親と異なる(§7-9 の実測)。そのまま適用すると、子の Stop が親のエントリを idle と未確認にし、子の SessionEnd が親のエントリを削除する。
  hook の report は、上記「pid による統合」の「hook の report」の (a) または (b) で決めたエントリについて、次の順で判定する。target の種類に関係なく、同じ規則である
  1. report の `session_id` が、エントリの `session_id` と同じ場合は、適用する。
  2. 異なる場合で、report に `pid` が無い、エントリの `pid` が不明、または 2 つの `pid` が異なるときは、適用する
     (同じタブで `claude` を起動し直した場合と、pid で判定できない場合。`session_id` を上書きする — 上記「上書き規則」)。
  3. `session_id` が異なり、`pid` が同じ場合は、同じプロセスの別のセッションの report である。**SessionStart で、`source` が `clear` または `resume` のものだけを適用する**
     (そのプロセスの中でのセッションの切り替え。`session_id` を上書きして、§3.4 の SessionStart の行を適用する)。
     **それ以外の report は無視する**(エントリを変更しない。`last_seen` と `last_report_at` も更新しない。SessionEnd でも削除しない)。
     daemon の `info` の `last_report_at`(daemon が最後に report を受信した時刻 — §4.2)は、無視した report でも更新する(hook が届いていることの診断に使用する値である)。

  規則が前提にしている順序は、次のとおりである(§7-3)。`/clear` は、SessionEnd(`reason` が `clear`。切り替えの前の `session_id`)、SessionStart(`source` が `clear`。新しい `session_id`)の順に
  report を送信する。SessionEnd は 1 で適用してエントリを削除し、SessionStart は未登録として登録する。daemon が 2 つの report を逆の順で受信した場合は、SessionStart を 3 で適用し、
  その後に受信する SessionEnd(エントリの `session_id` と異なる)を 3 で無視するので、エントリは残る。`/compact` の SessionStart は、`session_id` が変化しないので、1 で適用する。
  この規則で扱えない場合は、次のとおりである(どれも、次の reconcile が、`claude agents` の一覧の `session_id` と status でエントリを上書きして回復する — §3.5 の 3 の「既知」)
  - エントリの `pid` が不明の間(daemon の起動の後)に受信した子の report は、2 で適用する(親のエントリを上書きする)
  - 親のエントリが無い間に受信した子の report は、未登録として登録する(親の report と区別できない)。その後の親の report は、3 で無視する
  - 子が `--resume` を指定して起動され、SessionStart の `source` が `resume` の場合は、3 で適用する(親のエントリの `session_id` を上書きする)
  - `source` が `fork` の SessionStart(セッションの中での分岐など)と、上記以外の `source` は、3 で無視する。セッションの中での切り替えで、
    Claude Code が送信する report の `source` と `reason` は、`/clear` 以外は実測していない(§7-9)
- **`target` を持たない SessionEnd**(制御端末が無くなった後の SessionEnd で、エントリを削除する。§8.66): ターミナルのウィンドウを閉じて終了したセッションでは、
  SessionEnd の hook が実行される時点で、`claude` のプロセスも、その祖先も、制御端末を持たない(§7-12)。hook は、祖先 walk で pid と tty を取れないので、
  `target` と `pid` を持たない SessionEnd の report を送る(§4.1)。daemon は、次の規則で適用する
  - **`session_id` が、report の `session_id` と同じエントリを、すべて削除する**(通常は 1 つである。配信は、エントリごとの `agent_removed` で、
    reason は、`target` を持つ SessionEnd と同じ `session_end` である)
  - 一致するエントリが無い場合は、何もしない(エントリを登録せず、配信せず、`state.json` を書き込まない)
  - この report に、応答は返さない(`target` を持つ report と同じ — §4.2)。daemon の `info` の `last_report_at` は、一致するエントリの有無に関係なく更新する
  - **上記「入れ子のセッション」の判定は行わない**: 対象を `session_id` の一致だけで決めるので、子の SessionEnd(`session_id` が親と異なる)が、
    親のエントリを削除することは無い
  - エントリの `session_id` は、target の付け替えで引き継ぎ(上記「付け替え」)、`state.json` にも保存するので、ウィンドウを閉じた直後の reconcile で
    `process:<pid>` に付け替わったエントリ(§3.5)と、daemon の起動の後の、`pid` が不明のエントリも、同じ規則で削除する
  - `target` を持たない、SessionEnd 以外の report は、不正な要求である(hook は送らない — §4.1)。daemon は、エラーの応答を返し(§4.2)、
    状態を変更しない(`info` の `last_report_at` も更新しない)
  - `target` を持つ SessionEnd は、上記「pid による統合」の「hook の report」のとおりである

  この規則で対応できない場合は、次のとおりである。hook が実行されない終了(プロセスの強制終了、クラッシュなど)では、report が無いので、
  エントリは reconcile の prune で削除する(下記「削除経路」)。ウィンドウを閉じてから SessionEnd の hook までの時間(約 3.5〜5.5 秒 — §7-12)は、行が残る。
  その間に走査が完全な reconcile があると、行は、SessionEnd までの間、`process:<pid>` の行(ジャンプできない行)になる
- **時刻はすべて daemon の時計**(epoch 秒)。report の `ts` は表示用。daemon 内の時計は注入可能にする(stale テストのため)
- **削除経路**: (1) SessionEnd(hook・即時。`target` を持つものと、持たないもの — 上記) (2) reconcile の prune(claude agents に居ない) (3) stale
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
- **target の生成規則**(§2 の対応ターミナルの 3 種のどれかを導出し、どれも導出できなければ **`process:<pid>` にする** —
  ジャンプはできないが、状態と通知の対象にする。§8.66):
  - **対話でない方法で起動したセッションの report は、すべて drop する**(§8.67): hook の環境変数 `CLAUDE_CODE_ENTRYPOINT` の値が `sdk-cli` の場合は、
    祖先 walk を実行せず、何も送らずに exit 0 で終了する(SessionEnd も送らない。エントリを登録していないため)。
    `claude -p` のセッションの hook は、どのイベントでも、この値を持つ(§7-13)。変数が無い場合、空の場合、値が `sdk-cli` 以外の場合は、下記の処理に進む
  - **上記に該当しない report では、最初に祖先 walk を実行する**: hook のプロセスは端末から切り離されて起動される(`ps` で `??`。§7-7)ので、
    **親方向に、最初に制御端末を持つプロセスまで辿り、そのプロセスの pid と tty を取る**(Terminal.app、iTerm2、Ghostty の実測では、hook の `sh` の親の `claude` 本体が持つ —
    §7-7・§7-8・§7-9。上限は §9)。**上限まで見つからなければ、report を drop する**(ターミナルを持たないセッション —
    エディタの拡張機能、常駐プロセスが起動する実行など — は追跡しない。§8.66)。
    **ただし、イベントが SessionEnd のときは、drop せずに、`target` と `pid` を持たない report を送る**(ターミナルのウィンドウを閉じて終了したセッションは、
    SessionEnd の時点で、`claude` のプロセスも祖先も制御端末を持たない — §7-12。daemon は、`session_id` が一致するエントリを削除し、
    一致するエントリが無ければ何もしないので、ターミナルを持たないセッションの SessionEnd を送っても、エントリは登録されない — §3.6「`target` を持たない SessionEnd」)。
    この report では、下記の target の分岐を実行しない(環境変数の `ITERM_SESSION_ID` などが残っていても、target にしない)。
    取った pid は、target の種類に関係なく、report の `pid` として送る(§4.2)。
    walk は、`shiibar-cc report` のプロセス自身から開始する。**この規則は、hook のプロセスと、その親のシェルが、制御端末を持たないことに依存する**
    (持つ場合は、`claude` ではなく、hook のプロセスの pid を取る。ターミナルの種類ごとの確認は §7-9)。
    実行中のセッションが起動した、制御端末を持たない子の `claude` の hook は、親の `claude` の pid と tty を取る
    (daemon が、`session_id` の違いで無視する — §3.6「入れ子のセッション」。子が `claude -p` の場合は、上記のとおり、hook が report を送らない)
  - `TERM_PROGRAM` が `iTerm.app` で、**かつ** `$ITERM_SESSION_ID`(形式 `wNtNpN:UUID`。§7-1)があれば
    `iterm2:<UUID>`(`:` 以降の UUID。reconcile が AppleScript から導出する target と一致させるため。
    `wNtNpN` は含めない。§2)。`ITERM_SESSION_ID` の有無だけでは判定しない —
    iTerm2 から起動した VS Code 等に相続されて残り、起動元タブの UUID を誤って指すため(§7-1)
  - `TERM_PROGRAM` が `Apple_Terminal` なら `apple-terminal:<tty パス>`(tty は祖先 walk で取った値)。
    `TERM_SESSION_ID` は判定にも target にも使わない(AppleScript 側に対応物が無い。§7-7)
  - `TERM_PROGRAM` が `ghostty` で、**かつ** `TERM_PROGRAM_VERSION` が 1.4.0 以上(§9)なら `ghostty:<tty パス>`(tty は祖先 walk で取った値)。
    バージョンは、最初の `-` または `+` より前の部分を、`major.minor.patch` の 3 つの数値として解釈する(リリースではないビルドの値は、
    `1.4.0-main+abc1234` のように、3 つの数値の後ろに `-` と `+` で始まる部分を持つ — §7-8)。`TERM_PROGRAM_VERSION` が無い、
    解釈できない、1.4.0 未満のいずれかのときは `process:<pid>` にする(1.4.0 未満の Ghostty の扱いは §7-8)。
    `GHOSTTY_SURFACE_ID` は判定にも target にも使わない(AppleScript の `id` と一致しない。§7-8)
  - 上のどれにも該当しない(`TERM_PROGRAM` が別の値、または無い。`iTerm.app` で、`ITERM_SESSION_ID` が無い、空、`:` を含まない、
    `:` の後が空、のいずれかの場合を含む)ときは `process:<pid>`(pid は祖先 walk で取った値)
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
// (fire-and-forget。EOF を接続終了として扱う)。
// どの report も "pid":48213 の形で、そのセッションを実行している claude のプロセスの pid を運ぶ(§4.1。任意の項目。
// 無い report は、pid が不明として扱う — §3.6「pid による統合」)
{"cmd":"report","event":"Notification","notification_type":"permission_prompt","message":"Bash: cargo test",
 "target":"iterm2:D2DA6A1F-…","session_id":"…","cwd":"/path","transcript_path":"…","pid":48213,"ts":1751600000}
{"cmd":"report","event":"UserPromptSubmit","prompt":"focus の AppleScript を実装して",
 "target":"…","session_id":"…","cwd":"…","transcript_path":"…","ts":1751600060}
{"cmd":"report","event":"Stop","target":"…","session_id":"…","cwd":"…","transcript_path":"…",
 "background_tasks":[],"last_assistant_message":"Done. All 54 tests pass.","ts":1751600123}
// 制御端末を持つ祖先が無い状態で実行された SessionEnd(ターミナルのウィンドウを閉じて終了したセッション。§4.1)。
// target と pid の項目を持たない(項目を出力しない。daemon は、"target":null も、項目が無い場合と同じに読む)。
// daemon は、session_id が一致するエントリを削除する(§3.6「target を持たない SessionEnd」)。応答は返さない
{"cmd":"report","event":"SessionEnd","session_id":"…","cwd":"…","transcript_path":"…","ts":1751600200}
// target を持たない report は、SessionEnd だけである。ほかのイベントの、target を持たない report には、次のエラーを返し、状態を変更しない
// → {"ok":false,"error":"invalid request: report without target is only valid for SessionEnd"}

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
//      "session_end"(hook)/ "stale" / "remove"(手動)/ "prune"(reconcile)/
//      "rekey"(エントリの target を付け替えた。§3.6「pid による統合」。このときだけ "to":"<新しい target>" を持ち、
//      直後に、新しい target の status_changed が続く)。
//      アプリは通知の掃除で session_end を除外するのに使う(§4.5)。未知の reason は "remove" と同扱いでよい
//    (last_seen だけの更新では配信しない)

// reconcile(claude agents の live 一覧を client が gather して送る。§3.5)
// daemon が claude agents を正として add / update / prune / flag を適用する。
// complete = 試みたターミナル走査がすべて完全だったか。false(または欠落)なら prune を行わない(§3.5)
// pid = claude agents の一覧の pid(任意の項目)。update_only = true のセッションは、登録済みのエントリ(target が同じ、
// 無ければ pid が同じ)の更新だけに使用し、エントリの作成と target の付け替えを行わない
// (走査が不完全な回の、どの走査にも一致しないセッション。§3.5・§3.6「pid による統合」。欠落は false)
{"cmd":"reconcile","complete":true,"sessions":[
  {"target":"…","session_id":"…","cwd":"…","status":"waiting","waiting_for":"permission prompt","pid":48213}
]}  // → {"ok":true}
{"cmd":"reconcile","complete":false,"sessions":[
  {"target":"process:48301","session_id":"…","cwd":"…","status":"idle","pid":48301,"update_only":true}
]}  // → {"ok":true}

// エントリの手動削除・既読化(shiibar-cc remove / seen。seen は、focus の成功時、アプリで利用者が選択した行の選択が続いた時点、Mark all as read で送られる)
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
- **target の種類**: daemon は target を解釈しない(§2。§3.6「pid による統合」は、target の文字列の一致と `pid` だけで判定する)。
  クライアントは、target の prefix で、そのセッションのタブへジャンプできるかどうかを判定する —
  `iterm2:` / `apple-terminal:` / `ghostty:` はジャンプできる。`:` を含まない、空でない target と、`wNtNpN:UUID` の形式の target
  (`:` の後が空でないもの)も、ジャンプできる(iTerm2 に振り分ける互換の形式 — §4.3「振り分けの規則」)。
  `process:`、クライアントが知らない prefix、空の target、`wNtNpN:` の後が空の target は、ジャンプできない。
  ジャンプできるかどうかを示す項目は、ワイヤに設けない(`target` は、SessionEnd の `report` を除いて、どの要求と応答でも必須の文字列である。§8.66。
  `target` を持たない SessionEnd の `report` は、§3.6「`target` を持たない SessionEnd」。この `report` は、`target` の項目を出力しない。
  daemon は、値が `null` の `target` も、項目が無い場合と同じに読む)
- **`pid` は、一覧と購読の応答には含めない**(エントリの `pid` は、daemon が統合に使用する値で、クライアントは使用しない)
- **付け替えの後の target**: reason が `rekey` の `agent_removed` の後は、古い target を指定した `seen` と `remove` は、未登録の target への要求と同じ結果になる
  (`ok` を返して、何も変更しない)。古い target を対象にした `wait` は、エントリが削除されたものとして終了する
- **アプリ、daemon、CLI は、同じバージョンを一緒に配布する**(アプリのバンドルに同梱する)。アプリは、バージョンが異なる daemon に
  アタッチしない(起動中の daemon を終了させて、同梱の daemon を起動する — §4.5「daemon のライフサイクル管理」)ので、
  アプリを起動している間は、`rekey`、`to`、`pid`、`update_only` を知らない daemon との組み合わせにならない
  (バージョンが異なる daemon にアタッチする場合の例外は、§4.5「daemon のライフサイクル管理」)
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
  **ターミナルモジュール(iterm2 / apple_terminal / ghostty)**
    (モジュール名は target の prefix と同名 — ハイフンは Rust の識別子制約でアンダースコアになる)
  - `wait` は subscribe 1 本で実装する(最初に snapshot が来るので、別途 list を叩く必要はない)
  - **ターミナルモジュールの共通規則**: 各ターミナルの知識(ID 形式・AppleScript)はそのモジュールに
    のみ存在させる。target の prefix(§2)で同名のモジュールに振り分ける入口を 1 箇所だけ持ち、
    trait 等の抽象層は作らない(§8.2・§8.66 — 実物 3 例の共通部分は「対になる 5 関数」
    (focus / focused / probe / <ターミナル>_targets / open_resume_window)までで、それ以上を固定しない。
    ターミナルの知識を含まない純関数(tty の正規化など)は、モジュールの間で共有してよい)。
    **振り分けの規則**: `iterm2:` → iterm2、`apple-terminal:` → apple_terminal、`ghostty:` → ghostty。
    `process:` は、どのモジュールにも渡さず「該当なし」にする(ジャンプできない target — §2)。`:` を含まない target は
    `iterm2:` とみなす(§2 の移行前の値・手打ち UUID の互換。アップグレード前に配信済みの
    通知が持つ旧 target もこれで飛べる)。prefix 部が `wNtNpN` 形式なら `:` 以降を UUID として
    iterm2 に渡す(`$ITERM_SESSION_ID` を手で貼る利用の互換)。それ以外の未知 prefix は「該当なし」
    (exit 2 系統 — 黙って iterm2 に流さない)。
    `focused` は、iterm2、apple_terminal、ghostty の順に照会し、最初に target を返したモジュールの結果を返す(最前面のアプリは 1 つなので、順序は結果に影響しない)。
    **テスト分離**: AppleScript ソースの生成と osascript 出力のパースは純関数として切り出し、
    osascript プロセス実行部だけを差し替え可能にする(全モジュール共通)。
    **ターミナルの固有の用語を使用するスクリプトは、そのターミナルが起動中であることを、別のスクリプトで確認した後に送る**
    (iterm2 と ghostty。`open_resume_window` を除く): アプリの固有の用語を `tell` の中で使用するスクリプトは、そのアプリがインストールされていない Mac では、
    実行の前にエラーになり、同じスクリプトの中の is-running の確認は実行されない(§7-10)。この場合に、focus と focused が「該当なし」ではなくエラーになり、
    reconcile の走査が毎回不完全になって prune が止まる(§3.5)。そのため、固有の用語を使用しない照会だけのスクリプトを先に送り、
    起動中の場合だけ、固有の用語を使用するスクリプトを送る。アプリは名前で指定する(`application "iTerm2"` / `application "Ghostty"`。
    バンドル ID で指定したスクリプトは、インストールされていないアプリでは、実行の前にエラーになる — §7-10)。
    固有の用語を使用するスクリプトの中の is-running の確認は、残す(2 つのスクリプトの間でアプリが終了した場合に、起動させないため)。
    apple_terminal は、対象の Terminal.app が macOS に含まれるので、1 つのスクリプトのままである。
    `open_resume_window` は、選択したターミナルを起動する操作なので、事前の照会を送らない(ghostty は、起動中の場合のバージョンの確認だけを送る)
  - **iterm2 モジュール**(iTerm2 の知識はここにのみ存在させる)
    - `focus(target)`: target(振り分け入口で `iterm2:` を外した裸の UUID。§2)を使い、
      AppleScript で iTerm2 の windows→tabs→sessions を走査し、一致を見つけたら
      **`activate` してから** window・tab・session(pane)を select する(activate が後だと、
      別アプリがアクティブな状態からの focus で今の Space のウィンドウが select に勝ち、
      別 Space へ遷移しない — §7-1)。一致なしは「該当なし」(activate は一致分岐の中のみ —
      該当なしでは何も動かさない)。
      **iTerm2 が起動していなければ起動せずに「該当なし」を返す**(走査は `application "iTerm2" is running` ガード内)。
      **focus / focused / probe / `iterm2_targets` は、最初に、`application "iTerm2" is running` だけを照会するスクリプトを送る**
      (`tell` と iTerm2 の用語を含まない — 上記「共通規則」)。起動していない場合は、2 つ目のスクリプトを送らずに、それぞれ「該当なし」/「なし」/「未起動」/
      空の結果(完全な走査。`ps` も実行しない)を返す。この照会の失敗は、TCC のエラーはそのまま返し、それ以外のエラーは、
      focus / focused / probe ではエラー、`iterm2_targets` では不完全な走査として扱う
      走査は明示 index + `try`(分割ペインで `index of tab` / plural 反復が `-1719/-1728` になる実機バグ回避。§7-1)
    - `focused()`: iTerm2 が最前面アプリのとき、前面 session の target(`iterm2:<UUID>`。§2)を返す。前面でなければ「なし」
    - `probe()`: doctor 用。起動中の iTerm2 に、状態を変更しない照会(`count of windows`)を 1 回送り、オートメーションの権限の有無を返す。
      iTerm2 が起動していなければ、照会を送らずに「未起動」を返す
    - `iterm2_targets(pids)`: **reconcile 用**。渡された pid(`claude agents --json` 由来)を `ps` で tty に引き、
      iTerm2 の各セッションの tty と突き合わせて `{pid → target(`iterm2:<UUID>`)}` を返す(§3.5 / §7-1)。
      iTerm2 に無い pid は返さない(iTerm2 外 = このモジュールの対象外)
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
      Merge 等で 1 window 複数 tab の形も存在するため — 両形態を同じループがカバーする(§7-7 実測)。
      **タブを読み取れないウィンドウは、読み飛ばす**(各ウィンドウの `tabs of w` の読み取りと、各タブの `tty` の読み取りを、それぞれ `try` の中に置く)。
      Terminal.app は、ターミナルのウィンドウをすべて閉じた後も、`id` もタブも読み取れないウィンドウのオブジェクトを保持する場合があり(§7-7)、
      その読み取りのエラーで、ほかのウィンドウのタブへの focus が失敗しないようにするためである。
      `activate` と選択の操作(`set selected`、`set frontmost`)は、どの `try` の中にも置かない(これらのエラーは、「該当なし」ではなく、エラーとして返す)
    - `focused()`: Terminal.app が最前面アプリのとき、前面 window の selected tab の target
      (`apple-terminal:<tty パス>`)を返す。前面でなければ「なし」。
      前面のウィンドウの selected tab を読み取れず、そのウィンドウの `id` も読み取れない場合(ターミナルのウィンドウが無い状態 — §7-7)も、「なし」を返す。
      `id` を読み取れるウィンドウで読み取りが失敗した場合は、エラーとして返す。最初に `count of windows` を `try` の外で照会するので、TCC のエラーは「なし」にならない
    - `probe()`: doctor 用。起動中の Terminal.app に、状態を変更しない照会(`count of windows`)を 1 回送り、オートメーションの権限の有無を返す。
      Terminal.app が起動していなければ、照会を送らずに「未起動」を返す(is-running ガード)。
      `count of windows` は、`id` もタブも読み取れないウィンドウだけがある状態でも成功する(§7-7)
    - `apple_terminal_targets(pids)`: **reconcile 用**。渡された pid を `ps` で tty に引き、Terminal.app の
      各タブの tty と突き合わせて `{pid → target(`apple-terminal:<tty パス>`)}` を返す(§3.5)。
      `ps` の tty は `/dev/` 無し・AppleScript は `/dev/` 付き(§7-7)なので前置して比較する。
      **タブを読み取れないウィンドウの扱い**: `tabs of w` を読み取れず、`id of w` も読み取れないウィンドウは、ターミナルのウィンドウではないものとして、
      失敗に数えずに読み飛ばす(§7-7)。`tabs of w` を読み取れず、`id of w` を読み取れるウィンドウは、失敗 1 件に数える(その回の走査は不完全 — §3.5)。
      タブの `tty` を読み取れない場合も、失敗 1 件に数える。読み飛ばす規則が無いと、Terminal.app がターミナルのウィンドウを持たずに起動している間、
      走査のスクリプトがエラーになり、reconcile が毎回不完全になって、ほかのターミナルの終了したセッションも prune されない
    - `open_resume_window(cwd, session_id, fork)`: 新しい Terminal.app ウィンドウで cwd の `claude --resume` を
      実行する(`fork` の扱いは iterm2 と同じ)。起動方式は **`do script`**(新しいウィンドウの対話シェルにコマンドを打ち込む —
      iterm2 の `write text` と同じく rc を通った PATH で `claude` を解決するため)。
      Terminal.app が起動していなければ起動する(iterm2 と同じ「開く動詞」の例外)。
      エスケープ規則も iterm2 と同じ
    - split pane(Cmd+D)は同一セッションの表示分割で独立した tty を持たない(§7-7 実測)ため、
      pane の概念はこのモジュールに存在しない
  - **ghostty モジュール**(Ghostty の知識はここにのみ存在させる。実測の根拠と未検証の点は §7-8。対象は Ghostty 1.4.0 以上 — §9)
    - 鍵は tty である(apple_terminal と同じ)。Ghostty の AppleScript の `terminal`(ウィンドウ・タブ・分割の中の 1 つの端末)が
      `tty` を持つ。分割した端末は、それぞれ別の `terminal` と `tty` を持つので、別の target として扱う(§7-8)
    - **1.4.0 未満の Ghostty**: どの関数も、最初に、起動中の Ghostty のバージョン(AppleScript の `application` の `version`)を確認する。
      比較の規則は §4.1 と同じである(最初の `-` または `+` より前の部分を、3 つの数値として解釈する)。1.4.0 未満のときは、
      `tty` を参照せず(`v1.3.1` の `terminal` には `tty` が無い — §7-8)、focus と focused は「該当なし」、`ghostty_targets` は空の結果を完全な走査として返す
      (その Ghostty のセッションは、hook でも reconcile でも `process:` になる — §4.1・§3.5)。`open_resume_window` は、専用のエラー
      (`Ghostty 1.4.0 or later is required. Quit and reopen Ghostty after updating it.`)を返す(CLI は exit 1 — §4.4。
      インストールされている Ghostty が 1.4.0 以上でも、起動中の Ghostty が古い場合に発生する)
      このバージョンの照会が、上記「共通規則」の、起動中であることを確認するスクリプトを兼ねる: アプリを名前(`application "Ghostty"`)で指定し、
      is-running の確認の中で `version` だけを取得する(Ghostty の固有の用語を含まない)。Ghostty がインストールされていない Mac でも、
      「未起動」を返す。`tty` などの固有の用語を使用するスクリプトは、この照会が 1.4.0 以上の起動中の Ghostty を返した場合だけ送る
    - **端末の列挙は、1 回の照会で一括して取得する**(`tty of every terminal` の形)。`terminal` を 1 つずつ取り出す列挙は、
      列挙の途中で端末が閉じられると、エラー(-1719)になる(§7-8)。**照会がエラーになった場合(`version` の照会を含む。-1719 を含む。TCC のエラーを除く)は、
      不完全な走査として扱う**(reconcile は、その回の prune を行わない — §3.5)。AppleScript を無効にした Ghostty(設定 `macos-applescript` が false)での
      照会の結果と、その場合の扱いは、未検証である(§7-8)
    - `focus(target)`: target(`ghostty:` を外した tty パス)で、`every terminal whose tty is "<tty パス>"` を取得し、最初の 1 つに
      `focus` コマンドを実行する。`focus` だけで、その端末のウィンドウが前面のウィンドウになり、タブと分割が選択される
      (`activate window` と `select tab` は併用しない — §7-8)。一致なし(0 件)は「該当なし」(何も動かさない)。
      **Ghostty が起動していなければ起動せずに「該当なし」を返す**(is-running ガード。iterm2 と同じ)。
      別のアプリが前面にある状態から、Ghostty が前面のアプリになるかどうかと、別の Space にある端末への移動は、未検証である
      (前面にならない場合は、一致の分岐の中で、`focus` の前に `activate` を実行する — iterm2 と同じ順。§7-8)
    - `focused()`: Ghostty が最前面アプリのとき、前面のウィンドウの選択中のタブの `focused terminal` の target
      (`ghostty:<tty パス>`。`tty of focused terminal of selected tab of front window`)を返す。前面でなければ「なし」。
      最前面かどうかは、Ghostty の `application` の `frontmost` で判定する(§7-8)
    - `probe()`: doctor 用。起動中の Ghostty に、状態を変更しない照会(`version` の取得)を 1 回送り、オートメーションの権限の有無を返す。
      Ghostty が起動していなければ、照会を送らずに「未起動」を返す(iterm2 と同じ)
    - `ghostty_targets(pids)`: **reconcile 用**。渡された pid を `ps` で tty に引き、Ghostty の全 `terminal` の tty(上記の一括の取得)と
      突き合わせて `{pid → target(`ghostty:<tty パス>`)}` を返す(§3.5。`/dev/` の前置は apple_terminal と同じ)
    - `open_resume_window(cwd, session_id, fork)`: 新しい Ghostty のウィンドウを開き、その対話シェルで
      `cd … && claude --resume …` を実行する(`fork` の扱い、rc を通った PATH で `claude` を解決する理由は iterm2 と同じ)。
      起動方式は、**surface configuration の `initial input`** である: `new surface configuration` で作成したレコードの `initial input` に、
      コマンドと、末尾の改行(AppleScript の `linefeed`)を指定して、`new window with configuration` を実行する。末尾の改行によって、コマンドは、対話シェルの入力として実行される(§7-8)。
      `new window` の前に `activate` を実行する(新しいウィンドウを前面にする。iterm2 と apple_terminal の `open_resume_window` と同じ)。
      `input text` は、文字列を貼り付けとして入力するので、改行を含めても実行されない(実行には `send key "enter"` が必要になる)。そのため、使用しない。
      surface configuration の `command` の直指定も採らない(ログインシェルの PATH の構築を迂回する — iterm2 と同じ理由)。
      エスケープは 2 段である: cwd と session_id を、シェルの単一引用符で囲み(中の `'` は `'\''` にする)、できたコマンドの文字列を、
      AppleScript の文字列としてエスケープする(`\` と `"`)。Ghostty が起動していなければ起動する(iterm2 と同じ「開く動詞」の例外。
      未起動の状態からの動作は、未検証である — §7-8)
  - osascript の TCC(オートメーション)権限エラーは「該当なし」と区別して呼び出し元に返す(全モジュール共通)

### 4.4 shiibar-cc(`crates/shiibar-cc`)

```
shiibar-cc report <event>     # hooks 専用: stdin の hook JSON を整形して daemon に送信(M1 で前倒し実装)
shiibar-cc list [--json]      # 非 --json は「状態 / ラベル / 経過時間 / target」の整列テキスト
shiibar-cc wait <selector> --status waiting|idle|working [--timeout SEC]
shiibar-cc watch              # subscribe のイベントを行 JSON で標準出力へ
shiibar-cc focus <selector>   # ジャンプ。成功時: daemon に seen を送る
shiibar-cc focused            # 前面の対応ターミナル(iTerm2 / Terminal.app / Ghostty)の前面セッションの target を出力(なければ exit 2)
shiibar-cc reconcile          # claude agents + ターミナル走査(iterm2_targets / apple_terminal_targets / ghostty_targets)を gather → daemon に reconcile を送る(§3.5)。アプリが起動時・再接続時・定期(§4.5)・Refresh で呼ぶ
shiibar-cc remove <selector>  # 幽霊エントリの手動削除(通常は reconcile が自動で消す)
shiibar-cc seen <selector>    # unreviewed フラグを消す(daemon に seen を送る。アプリが、利用者が選択した行の選択が続いた時点と、Mark all as read で target ごとに呼ぶ。§4.5)
shiibar-cc resume --cwd <dir> [--terminal iterm2|apple-terminal|ghostty] [--fork] <session-id>  # 新しいターミナルウィンドウを開き <dir> で claude --resume を実行(既定 iterm2。--fork は分岐。アプリの Resume / Branch が呼ぶ。§4.6)
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
  **`process:` の target は、ジャンプできないので exit 2**(osascript を実行しない。stderr に、対応ターミナル以外で実行中のセッションである旨を出す —
  `shiibar-cc focus: the session is running in a terminal Shiibar CC can't drive; there is no tab to jump to`。タブが見つからない場合の文言とは別である。
  `.` で解決したエントリの target が `process:` の場合も同じ)。`seen` / `remove` / `wait` は、`process:` の target を、ほかの target と同じに扱う。
  daemon の list を引くのは `.`(cwd 一致)を解決するときだけ。focus 成功後の `seen` 送信は
  best-effort(失敗しても飛べた事実は覆さない)
- **exit code(全サブコマンド共通)**: 0 成功 / 1 接続・内部エラー(daemon 不在含む。stderr に理由) /
  2 該当なし(wait では対象消滅。理由は stderr に出す) /
  3 osascript 権限(TCC)エラー / 124 wait タイムアウト。
  **例外は `report` のみ**: hooks を阻害しないため、daemon 不在・タイムアウトを含め常に exit 0(§4.1)。
  **reconcile は、1 つのターミナルの走査が TCC エラーになっても、ほかのターミナルの走査の結果を daemon に送ってから、exit 3 で終了する**
  (その回は `complete:false` である — §3.5。1 つのターミナルの権限の拒否で、ほかのターミナルと、対応ターミナル以外のセッションの照合を止めない)
- **wait の selector 解決**: 開始時に 1 回解決し、以降はその target を追う(未登録なら出現を待つ)。
  `--timeout` 省略時は無限に待つ
- **resume は daemon に接続しない**(ターミナルモジュール直呼び。§4.3 の `open_resume_window`)。
  引数は cwd と session_id の明示指定、`--terminal`(省略時 `iterm2`)、`--fork` である — 会話の知識
  (transcript)は持たない(それは conversations モジュール。§4.6)。**どのターミナルで開くかも
  自分では判断しない**: focus と違って飛び先のタブが存在せず target からも導けないため、
  呼び出し側 = アプリが、Settings の `Terminal` の値を渡す(§4.6)。
  CLI を直接使うスクリプトには `--terminal` が明示手段になる。
  **`--fork` を付けると、ターミナルで実行するコマンドに `--fork-session` を追加する**
  (`claude --resume <session-id> --fork-session`。その会話のコピーから新しい session ID の会話が始まり、
  元の会話は変更されない — 測定結果は §7-6)。違いはこのフラグだけで、ウィンドウの開き方・cwd の確認・
  exit code は `--fork` なしと同じ。**cwd は絶対パス必須で、実行前に存在を確認する**(相対パス・
  不存在は AppleScript に触る前に exit 1 — transcript はフォルダより長生きするため)。
  exit code は 0 成功 / 1 内部エラー / 3 TCC(共通系統のうち 2 と 124 は使わない)。
  起動中の Ghostty が 1.4.0 未満のときの `--terminal ghostty` は、exit 1 である(stderr には、ほかのエラーと同じ `shiibar-cc resume: ` の接頭辞に続けて、§4.3 の ghostty モジュールの文言を出す)
- **conversations 系も daemon に接続しない**(データ源は transcript と `~/.claude/sessions/` の
  pid ファイル。§4.6)。exit code: `index` / `search` は 0 成功(検索 0 件も成功)/ 1 内部エラー
  (索引構築不能・有効な検索語が無いクエリを含む — 黙って 0 件を返さない)。`show` は 0 / 1 / 2
  (session-id が索引に無い。人の発話が 1 つも無い transcript と、対話でない方法で起動した会話の transcript の session-id を含む — §4.6「索引の内容」)。出力は既定が人間向けテキスト、`--json` で機械可読(doctor と同じ 2 面性)
- **conversations の出力 JSON(スクリプトが依存してよい公開契約)**。命名は NDJSON プロトコルと同じ
  snake_case、時刻は epoch 秒、消費者は未知フィールドを無視する(§4.2 と同じ前方互換):
  - `search`: `{"conversations":[{"session_id","cwd","title","updated_at","live","last_prompt"}]}` —
    新しい順。`title` は null 許容(フォールバックは表示側の責任 — §4.6)。`last_prompt` は、
    その会話で最後の人の発話の先頭 1 行・80 文字(80 文字は §9 の task と同値)。型は null 許容である(消費者は null を空として扱う)。
    人の発話が 1 つも無い transcript と、対話でない方法で起動した会話の transcript は、会話として扱わないので、結果に含まれない(§4.6「索引の内容」)
  - `show`: `{"session_id","cwd","title","updated_at","messages":[{"seq","role"("user"|"assistant"),"text"}]}` —
    `text` は全文(切り詰めは表示側)。`updated_at` は、`search` の同じ会話の `updated_at` と同じ値である
    (会話ペインが、search を再実行せずに、終端マーカーの経過時間を求めるために使用する — §4.6「会話ペインの再読み込み」)
  - `index --json`: 行 JSON のストリーム — `{"event":"start","total":N,"full_build":B}` /
    `{"event":"progress","done":N,"total":N}`(間引きは §9)/ `{"event":"done","indexed":N,"removed":N}`(`removed` は、索引から消した、登録済みの会話の数である。
    人の発話が無くなって消した会話を含み、会話として登録していないファイルは数えない)/
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
  人間向け出力に `[info]` で明示し、黙って省略しない。検査の id は `tcc_iterm2` / `tcc_apple_terminal` / `tcc_ghostty` で、この順に検査する。
  Ghostty の検査は、バージョンの照会への応答で判定するので、起動中の Ghostty が 1.4.0 未満でも、応答があれば権限ありとして表示する — §4.3 の `probe`)/
  Space 切り替え設定(NSGlobalDomain の `AppleSpacesSwitchOnActivate` が明示 `0` なら warn —
  OFF だと focus がウィンドウのある Space / ディスプレイに切り替われない。§7-1。
  未設定・`1`・読み取り失敗は ok 扱い — 既定が ON のため誤警告より見逃しを選ぶ)。
  「通知が来ない」「飛べない」の切り分けはまずこれを実行する。
  **`--json`** で同じ検査結果を `{"checks":[{"id","status"("ok"|"warn"|"fail"),"summary","hint"}]}` として
  出力する(アプリの Setup Check が読む。exit code の意味は人間向けと同じ。判定ロジックは CLI 側が正。
  人間向け出力だけにある `[info]`(ターミナル未起動で TCC 未検査)は JSON では `ok` に畳む — 失敗ではないため)

### 4.5 メニューバーアプリ(`app/`)

SwiftUI(macOS 14+(§8.34))。メニューバーの**トレイアイコン**(全セッションの状態の
ロールアップ 1 つ。常時表示)と、2 つの画面(**ポップオーバー**と**ウィンドウ**)で構成する。アイコンのクリックは、
表示の形(下記「表示の形」)の画面を開く。ポップオーバーとウィンドウは同じ内容(実行中のセッションと過去の会話の一覧、および
会話の全文を表示する会話ペイン)を表示し、レイアウトは 1 種類である(§8.49)。通知クリックで focus(ジャンプできないセッションでは、一覧でその行を選択する — 下記「デスクトップ通知」)。

- **見た目の正**: トレイアイコンは `docs/menubar-design.html`、ポップオーバーとウィンドウは
  `docs/window-design.html`。
  トレイ = フルハイトの角丸窓 + 左上スロットの **1 グリフ** + working のときだけ下段の **3 つの点**、
  の**テンプレートアイコン**(「Claude が居る窓」)。スロットのグリフと 3 つの点の有無で、
  ロールアップを表す: waiting = **太い `!`**(紋章と入れ替え — あなたへの要求が窓に立つ)>
  working = **`✻` の下に 3 つの点** > idle = **`✻` だけ**(素の U+273B)。
  減光 2 段階: idle 0.8 / エージェントなし・切断 0.45。**枠の角の点**: waiting が 1 台でもいれば、オレンジの点。waiting がいなくて、
  unreviewed が 1 台でもいれば、アクセントカラーの点。どちらもいなければ、点を表示しない(オレンジを優先する。waiting のセッションは、
  確認済みでも、操作を待って止まっているためである)。点の色は、メニューバーのボタンの外観(明るいか暗いか)で解決した
  `systemOrange` と `controlAccentColor` で、点には明色のフチを付ける(menubar-design.html)。色は、画像を作成する前に、ボタンの外観で
  具体的な値(sRGB の成分)に解決し、その値を、描画と、下記の「表示する内容」の比較の両方に使用する(描画の時点の外観で解決すると、
  比較した色と描画した色が一致しない場合があるため)。daemon の切断中も、最後に受け取った一覧で点の種類を判定し、
  トレイ全体の減光と同じ濃度で表示する。
  描画は NSImage 合成で、状態が変化したときに再描画する。**トレイアイコンはどの状態も静止画で、
  アニメーションのタイマーを使用しない**。画像を設定するたびに、AppKit がメニューバーの表示を
  メインスレッドで作成し直し、その処理時間は画像の内容に関係なく一定である。そのため、画像を
  周期的に変更すると、working のセッションがある間、CPU を使用し続ける(§8.51)。
  **画像を設定するのは、表示する内容(グリフ・3 つの点の有無・減光・角の点の有無と色と、メニューバーが
  暗いかどうか)が前回の設定から変化したときだけである**。内容が同じ画像を毎回設定すると、
  処理が終了しない。画像を設定すると、AppKit がメニューバーの表示を更新し、その更新がボタンの外観を
  変更する。外観の変更は、外観の監視(角の点が付いた画像はテンプレート画像ではないので、外観に
  合わせた再描画に必要)を起動し、監視が画像をもう一度設定する。本節は挙動のみを規定する
- **daemon 接続**: `NWConnection` で UDS に接続し、subscribe の行 JSON を `JSONDecoder` でデコードする。
  切断時(daemon 再起動・スリープ復帰)は 1 秒から倍々・上限 30 秒のバックオフで再接続(snapshot で状態回復)。
  未知の event / status は無視する(前方互換)
- **表示の形**(§8.61): 一覧を表示する形は、**ポップオーバーの形**と**ウィンドウの形**の 2 つである。
  トレイアイコンのクリックとグローバルホットキーは、その時点の形の画面を開閉する(下記「トレイアイコンのクリック」)。
  形を変更する操作は、ポップオーバーの見出し行の `Open in window`(ウィンドウの形にする)と、ウィンドウの見出し行の
  `Open in popover`(ポップオーバーの形にする)だけである(下記「見出し行」)。ウィンドウを閉じる操作(赤ボタン、⌘W、
  トレイアイコンのクリック、グローバルホットキー)は、形を変更しない。形は UserDefaults に記憶し、アプリの再起動の後も保持する。
  記憶している値が無い場合と、値が不正な場合は、ポップオーバーの形にする。
  ウィンドウの形の間は、ポップオーバーを表示しない。ポップオーバーの形の間は、ウィンドウを表示しない。
  **アプリの起動時には、どちらの形でも、ポップオーバーもウィンドウも表示しない**(ウィンドウの形で終了した後の起動でも同じである。
  最初のトレイアイコンのクリックまたはグローバルホットキーで、ウィンドウを開く)
- **トレイアイコンのクリック**(§8.61): 表示の形(上記)によって、動作が決まる。
  アイコンはクリックを自分で受け取る(メニューやパネルを OS に開かせる形式にしない)。
  - **ポップオーバーの形**: ポップオーバーを開閉する(閉じている場合は開き、開いている場合は閉じる)
  - **ウィンドウの形**: ウィンドウの状態によって、次の表の動作を実行する

    | ウィンドウの状態 | 動作 |
    |---|---|
    | 閉じている | ウィンドウを開き、前面に移して、key にする |
    | 開いていて、前面ではない | ウィンドウを前面に移して、key にする(閉じない)。最小化しているウィンドウは、最小化を解除する。別の Space にあるウィンドウは、現在の Space へ移動する(Space は切り替えない)。ウィンドウの中のフォーカスは、変更しない |
    | 前面である | ウィンドウを閉じる(閉じた後の扱いは、下記「ウィンドウ」) |

    **ウィンドウが前面である**とは、次の 4 つの条件の全部が成立している状態を指す: アプリがアクティブである /
    このウィンドウが key である / ウィンドウを最小化していない / ウィンドウが現在の Space にある。
    1 つでも成立しない場合は、前面ではない(ほかのアプリが前面にある / アプリのほかのウィンドウ(Settings など)が key である /
    最小化している / 別の Space にある)。ピンが ON のウィンドウは、ほかのアプリのウィンドウより手前に表示されていても、
    key でない間は前面ではない。
    **前面かどうかは、クリックの直前の状態で判定する**(クリックそのものによる状態の変化は、判定に使用しない)
- **グローバルホットキー**(§8.50 / §8.61): 利用者が Settings で登録したキーの組み合わせ(下記「Settings ウィンドウ」)を、
  他のアプリが前面にある間も受け取る。初期状態は未登録であり、未登録の間は何も受け取らない。
  登録にはシステムのホットキーの API(Carbon の `RegisterEventHotKey`)を使用する
  (アクセシビリティの権限を要求しない。登録した組み合わせは、前面のアプリに届かなくなる)。
  ホットキーを押したときの動作は、フォーカスの扱いを除いて、トレイアイコンのクリックと同じである(上記「トレイアイコンのクリック」)。
  - ポップオーバーの形: ポップオーバーを開閉する(閉じている場合は開き、開いている場合は閉じる)
  - ウィンドウの形: 閉じているウィンドウを開き、前面でないウィンドウを前面に移して key にし、前面のウィンドウを閉じる。
    ウィンドウが前面かどうかは、ホットキーを押す直前の状態で判定する

  **ホットキーでポップオーバーまたはウィンドウを開いたとき(ウィンドウを前面に移したときを含む)は、検索欄ではなく一覧にフォーカスを移す**
  (閉じているウィンドウを開いたときは、ウィンドウが key になった時点で移す。開いてから §9 の時間の中で key にならなかった場合は、移さない)。
  **選択は変更しない**(選択なしの場合は、選択なしのままである。↑ / ↓ または Enter で、先頭の行を選択する — 下記「キー操作」。§8.66)。
  行が 1 つも無い場合は、検索欄にフォーカスを移す。
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
  Esc(Archive の一覧を表示している間を除く — 下記「キー操作」)/ ⌘W / `Open in window` / ⌄ メニューの About・Settings… / Jump・Resume・Branch の成功。
  Jump・Resume・Branch が失敗したときは閉じず、メッセージ行または警告行にエラーを表示する
  (Jump の該当なし — exit 2 — のときも閉じないが、エラーは表示しない。下記「実行のボタン」)。
  **他のアプリへの切り替えでは、アプリが非アクティブになった通知
  (`NSApplication.didResignActiveNotification`)を受信した時点で、アプリがポップオーバーを閉じる**
  (ポップオーバーの中からメニューを開いた後は、OS がポップオーバーを自動で閉じないため。§8.58)。
  ポップオーバーだけを表示している間、アプリは accessory のままである(`Open in popover` で開いたポップオーバーを除く。
  下記「ウィンドウを開いている間だけ、アプリは通常アプリになる」)。この間も、Edit メニューの
  標準ショートカット(⌘C / ⌘V / ⌘X / ⌘A / ⌘Z)と、アプリメニューのショートカット(⌘, / ⌘W / ⌘Q)は
  動作する
- **ウィンドウ**: ポップオーバーの見出し行の `Open in window` で開く(ポップオーバーは閉じる)。
  ウィンドウの形の間は、トレイアイコンのクリックとグローバルホットキーでも開く(上記「トレイアイコンのクリック」)。
  位置と大きさを記憶し、次も同じ位置と大きさで開く。初回は §9 の大きさで、ディスプレイの中央に開く。
  開いたときのフォーカスは、ポップオーバーを開いたときと同じである(1 列の一覧のページと 2 列では検索欄、1 列の詳細ページでは会話ペイン。
  グローバルホットキーで開いたときは、上記「グローバルホットキー」のとおり、一覧)。
  開いているウィンドウを、トレイアイコンのクリックで前面に移したときは、フォーカスを変更しない(グローバルホットキーで前面に移したときは、一覧に移す)。
  閉じる操作は、赤ボタン、⌘W、ウィンドウが前面のときのトレイアイコンのクリックとグローバルホットキーである
  (見出し行の `Open in popover` も、ウィンドウを閉じる。下記「見出し行」)。
  Esc では閉じない。Jump / Resume / Branch を実行しても閉じない
  (ターミナルが前面に移り、ウィンドウはその後ろに残る。ピンが ON なら手前に残る)。
  全 Space に追従しない。他の場所をクリックしても、他のアプリに切り替えても、閉じない。
  **ウィンドウを閉じると、キーの入力は、直前に前面だったアプリに戻る**(トレイアイコンのクリックまたはグローバルホットキーで
  閉じたときは、そのアプリで入力を続けられる。アプリのほかのウィンドウ(Settings など)を開いている場合は、そのウィンドウが key になる。
  `Open in popover` で閉じたときは、ポップオーバーが key になる)。
  閉じても、検索欄の文字・行の選択・表示中のページは保持する(下記「ポップオーバーとウィンドウは 1 つの状態を共有する」)
- **ポップオーバーとウィンドウは 1 つの状態を共有する**: 検索欄の文字・行の選択・表示中のページ
  (一覧のページまたは詳細ページ。下記「幅による切り替え」)・一覧のスクロール位置・
  会話ごとのスクロール位置は、
  アプリを終了するまで保持する。ポップオーバーまたはウィンドウを閉じて再度開いたとき、`Open in window` で
  ウィンドウに移ったとき、`Open in popover` でポップオーバーに移ったときのいずれも、
  同じ状態から操作を続けられる。
  例外: Archive の一覧を表示している間に閉じたとき(表示の形を切り替えたときを含む)は、通常の一覧に戻る(§4.6「Archive の一覧」。
  選択中の行が通常の一覧に無い場合は、選択なしになり、一覧のページに戻る)
- **ウィンドウを開いている間だけ、アプリは通常アプリになる**(§8.30): 開くと Dock と ⌘Tab に載り、
  画面上端にアプリメニューが表示される。閉じると accessory(常駐)に戻り、どちらも消える。
  ウィンドウの形(上記「表示の形」)でも、ウィンドウを閉じている間は accessory である。
  **`Open in popover` でウィンドウを閉じたときは、開いたポップオーバーを閉じるまで通常アプリのままにし、ポップオーバーを閉じた時点で accessory に戻す**
  (ポップオーバーを表示している間に accessory に戻すと、アプリが非アクティブになって、ポップオーバーが閉じる可能性がある。
  このポップオーバーから `Open in window` でウィンドウを開いたときは、通常アプリのまま、ウィンドウを開く)。
  ウィンドウを開いている間は、Dock アイコンのクリック・⌘Tab での切り替えはウィンドウを前面に移す。
  ポップオーバー / Settings を単独で開いても切り替えは起きない
- **見出し行**: ポップオーバーとウィンドウの上端は見出し行 1 行である。ポップオーバーは左から
  **検索欄 / Refresh / `Open in window` / ⌄**、1 列のウィンドウは **検索欄 / Refresh / `Open in popover` / ピン / ⌄** を並べる
  (Refresh は、ボタンの並びの左端にある。`Open in popover` は、ポップオーバーの `Open in window` と同じく、Refresh のすぐ右にあり、
  ピンはその右にある。検索欄の挙動は §4.6)。
  見出し行のボタンの大きさとアイコンは、文字の大きさに連動する(下記「文字の大きさ」)。
  **Refresh のボタン**は、§4.6 の Refresh を実行する(§8.62)。ほかの見出し行のボタンと同じ種類のボタンで、アイコンは時計回りの円弧の矢印、
  ツールチップは `Refresh (⌘R)` である(⌘R を画面の中で示す場所は、このツールチップである)。**Refresh の実行中は、アイコンが時計回りに回転し(回転の速さは §9)、ボタンは押せない**。
  実行中のツールチップは `Refreshing…` である。OS の「視差効果を減らす」の設定が ON の間は、アイコンは回転しない(ボタンは押せない状態にする)。
  押せない間は、ボタンを不透明度 40% で表示する(回転しない場合も、実行中であることが分かる)。
  `Open in window` は、ポップオーバーを閉じて、表示の形をウィンドウの形にし、ウィンドウを開く。
  `Open in popover` は、ウィンドウを閉じて、表示の形をポップオーバーの形にし、ポップオーバーを開く(上記「表示の形」)。
  ほかのボタンのツールチップは `Open in window` / `Open in popover` / `Keep on top`。
  `Open in window` のアイコンはウィンドウの枠、`Open in popover` のアイコンは、上の辺の近くにメニューバーの線があり、
  その下に上向きの矢印がある角丸の四角である(形は `docs/window-design.html`)。
  **2 列のウィンドウでは、見出し行は、2 つの列にまたがって、ウィンドウの幅の全体を使用する**(§8.62)。左から、
  信号機ボタン / 検索欄 / 会話の中のヒットのカウンタと ‹ ›(§4.6「ヒットナビゲーション」。表示するのは、検索中で、
  選択中の会話にヒットがある間だけである)/ Refresh / `Open in popover` / ピン / ⌄ を並べ、ボタンはウィンドウの右端に配置する。
  検索欄は、ポップオーバーと 1 列のウィンドウと同じく、次の要素の直前まで伸ばす(幅の上限は無い)。カウンタと ‹ › を表示している間は、
  その幅と間隔の分だけ、検索欄が短くなる。
  見出し行の下に、ウィンドウの幅の全体の区切り線を表示する。1 列のウィンドウとポップオーバーの見出し行は、この段落の先頭の並びである。
  ウィンドウのタイトルバーは非表示(タイトルを表示せず、タイトルバーを透明にする)で、見出し行は信号機ボタンと同じ高さに
  配置し、見出し行の上と下の余白を同じ値にする(下記「文字の大きさ」の「ウィンドウ」)。見出し行の空いている部分(信号機ボタンの周囲、余白、ボタンの間)でウィンドウをドラッグできる。ウィンドウの `title` は
  **Shiibar CC**(Mission Control 等の一覧表示と、実装のタイトルフィルタが使用する — 画面には描かれない)。
  **ウィンドウを全画面にしている間**も、見出し行を画面の上端に表示する(§8.62)。全画面では、OS がタイトルバーの領域を不透明の帯として表示し、
  見出し行に重なるので、全画面の間は、この帯を表示しない(タイトルバーの高さを確保するための空のツールバーを非表示にする)。
  全画面では信号機ボタンが無いので、見出し行と、1 列の詳細ページの会話ペインのヘッダは、信号機ボタンの分の左の空きを取らない。
  そのほかの並びと余白は、全画面でないウィンドウと同じである。OS がタイトルバーを表示したままにする場合(メニューバーを常に表示する設定など)は、
  画面の内容の全体を、タイトルバーの高さの分だけ下に配置する。ポインタを画面の上端に移動したときの、メニューバーと信号機ボタンの表示は、OS の標準の動作である
- **幅による切り替え**(§8.49): レイアウトは 1 種類で、表示する幅によって列の数だけが変化する。
  - **1 列**(幅が §9 のしきい値より狭いとき。ポップオーバーは常に 1 列): **一覧のページ**と
    **詳細ページ**のどちらか一方を表示する。一覧のページは、見出し行・一覧・固定フッターで構成する。
    詳細ページは、選択中の会話の会話ペイン(§4.6)だけで構成し、見出し行は表示しない
    (検索欄と見出し行のボタンは、一覧のページに戻って操作する。ウィンドウの詳細ページでは、
    会話ペインのヘッダの左端に信号機ボタンを配置し、ヘッダの空いている部分でウィンドウをドラッグできる)。
    ページの切り替えはスライドで、詳細ページは右から表示され、一覧に戻るときは右へ退く(時間は §9)
  - **2 列**(幅がしきい値以上のとき): 上端に、2 つの列にまたがる見出し行(上記「見出し行」)を表示し、その下の左の列に一覧、右の列に選択中の会話の会話ペインを表示する。
    左の列(一覧の列)の幅(§9)は、ウィンドウの幅を変更しても変化せず、右の列だけが伸縮する。
    ただし、右の列の最小の幅(§9)を確保できない幅のウィンドウでは、右の列を最小の幅にして、残りを一覧の列にする
    (2 列になる幅ちょうどのウィンドウでは、一覧の列は最小の幅である。文字の大きさとの関係は、次の「列の境界のドラッグ」)
  - **列の境界のドラッグ**(§8.53): 2 列のとき、列の境界を左右にドラッグして、一覧の列の幅を変更できる。
    境界の上では、カーソルを左右リサイズの形にする。ドラッグ領域(§9)は、その位置にある他の表示よりも先に
    マウスの操作を受け取る。ドラッグ中は、アニメーションなしで幅を追従させる。
    幅は、ドラッグを開始した時点の幅に移動量を加えて、範囲に収めた値である(範囲の端を超えた後に戻すと、
    境界がポインタの位置に追従する)。**幅の範囲**は、一覧の列の最小の幅(§9)から、ウィンドウの幅から
    右の列の最小の幅(§9)を引いた幅までである(その時点のウィンドウの幅で計算する。2 列になる幅ちょうどの
    ウィンドウでは、範囲の下限と上限が同じ値になり、幅を変更できない)。
    **幅の記憶**: ドラッグを終了した時点の幅(小数点以下は四捨五入)が、開始した時点の幅(同じく四捨五入)と
    違う場合に、その幅を UserDefaults に記憶する。移動のないクリックでは記憶しない。ドラッグ中に 1 列になった場合と、
    ウィンドウを閉じた場合は、ドラッグを終了し、記憶しない。
    **境界をダブルクリックすると、記憶した幅を消去して、既定の幅に戻す**(アニメーションなし。
    記憶した幅が無い場合は、何もしない)。
    **記憶した幅がある間**は、文字の大きさを変更しても、一覧の列の幅を変更しない(記憶した幅が無い間は、
    既定の幅を使用し、文字の大きさに連動する — 下記「文字の大きさ」)。表示する幅は、記憶した幅(無い間は既定の幅)を
    上記の範囲に収めた値である(記憶した値は変更しない。ウィンドウを狭めると、右の列に最小の幅を残して
    一覧の列が狭くなり、広げると、記憶した幅に戻る)。保存済みの値が数値でない場合と、0 以下の場合は、
    記憶した幅が無いものとして扱う。
    2 列になる幅(§9)は、一覧の列の最小の幅と右の列の最小の幅の合計で、記憶した幅、既定の幅、文字の大きさに関係なく一定である
  - **幅を変更したとき**: 詳細ページを表示したまま 2 列の幅まで広げると、同じ会話を選択した 2 列になる。
    2 列から 1 列の幅まで狭めると、一覧のページを表示する(選択は保持する)。
    **列の数が変化しても、キーの操作対象は変化しない**: 検索欄にフォーカスがある状態で変化した場合は、検索欄に
    フォーカスを保持する(入力中の文字とカーソルの位置も保持する)。一覧にフォーカスがある状態で変化した場合は、一覧にフォーカスを保持する
    (検索欄にフォーカスを移さない。選択中の行の色と、下部パネルのボタンの表示は変化しない)
- **ウィンドウのサイズ**: 縦横にリサイズできる。初回の大きさと最小の大きさは §9。記憶した大きさが最小の大きさより小さい場合は、
  ウィンドウを開くときに、左上の角の位置を保持して、最小の大きさにする。
  一覧は高さいっぱいに広がり、収まらない分はスクロールする。行数の増減でウィンドウの高さは変更しない
  (常駐する器の大きさは人が決める。§8.32)
- **一覧は 3 つの区画**(§8.49 / §8.60): 上から **Running**(daemon が追跡している実行中のセッション)、
  **Starred**(スターを付けた会話。§4.6「Starred の区画」)、**Recent**(それ以外の会話。§4.6「Recent の区画」)。
  Starred と Recent は、**History** の見出しの下に表示する(History は、この 2 つの区画をまとめる見出しである)。
  この文書の「History」と「History の行」は、Starred と Recent の 2 つの区画と、その行の総称である。
  - **見出しは 2 種類ある**(§8.63): Running と History の見出しは、**一覧の幅いっぱいの帯**である。帯は、左右に余白を空けず、角を丸めず、
    淡い灰色の地を持ち、上端と下端に区切り線を引く(2 列では、帯の幅は左の列の幅である)。Starred と Recent の見出しは、
    **地の無い、文字と線の見出し**である。名前と行数の右の、山形までの残りの幅に、区切り線と同じ色の細い線を引く。
    どの見出しも、左から、名前(太字)、行数、右端に山形を表示する(山形と、名前の前の点は、下記「区画の開閉」)。
    2 種類の見出しで、名前の左端は行の文字の左端に、山形の右端は行の記号と時間の列の右端にそろえる
  - **帯の位置**: 一覧の最初の要素が帯のときは、帯を、見出し行のすぐ下に、間を空けずに配置する(ポップオーバーと 1 列のウィンドウでは、帯の上端の線が、
    見出し行と一覧の境目になる。2 列では、見出し行の下の区切り線が境目になるので、最初の帯の上端の線を引かない)。
    それ以外の帯は、上の要素との間を空ける。帯と、その下の要素(行の枠、Starred または Recent の見出し、次の帯)の間も空ける
    (帯の高さと間隔は §9。寸法は `docs/window-design.html`)。帯は、一覧と一緒にスクロールする
  - **表示しない見出し**: 行が 1 つも無い区画は、見出しごと表示しない(閉じている区画の行も、行として数える。閉じている区画は、見出しを表示する)。Starred と Recent のどちらにも行が無いときは、
    History の見出しも表示しない。**Starred に行が無いときは、Recent の見出しも表示せず、History の見出しのすぐ下に
    Recent の行を表示する**(History の見出しが、Recent の見出しを兼ねる)
  - **行数**: Running、Starred、Recent の見出しは、その区画の行数を表示する(Recent の行が上限を超えている間の表示は、
    §4.6「Recent の区画」)。History の見出しは、Recent の見出しを兼ねている間だけ、Recent の見出しと同じ行数を表示する。
    それ以外の間は、行数を表示しない(検索中の見出しと行数は、§4.6「検索の適用範囲」)
  - **区画の行は、1 つの枠の中に、区切り線で区切って並べる**(§8.60): 枠は、角丸の枠線と地を持つ。行と行の間に隙間は無い。
    区切り線は、行の文字の左端から、枠の右端までの線である(寸法は `docs/window-design.html`)

  Running の行の状態は、行の右上の記号が示す。
  どの区画の行も、左に 3 行の文字、右に**記号と時間の列**を表示する(§8.59)。
  記号と時間の列は、上に記号、下に経過時間(ラベルと同じ文字の大きさと色)を表示し、どちらも**列の右端にそろえる**(§8.63)。
  列の上は、**Running の行では状態記号**、**History の行では、左からスター、三点リーダーのボタン**である(§4.6「スター」「Archive」)。
  状態記号、スター、三点リーダーは、同じ大きさの記号の枠(§9)の中に、中心をそろえて表示する。History の行の三点リーダーの枠は、
  Running の行の状態記号の枠と同じ位置(列の右端)にあり、スターの枠は、その左にある。列の幅と、記号の大きさは §9。
  記号の枠の上端は 1 行目(ラベル)の位置に、時間は 3 行目(最後の発話)の位置にそろえる。3 行の文字は、どの行も、列の手前で終わる(収まらない文字は、末尾を省略する)。
  経過時間の文字は省略しない(列の幅に収まらない場合は、その行の列の幅を、文字が収まる幅まで広げる)。
  行の左端に、記号のための場所は無い(文字は、行の左の余白から始まる)。
  **3 行は、上から、ラベル(小さい文字・二次色)、タイトル(太字)、最後の発話(小さい文字・二次色)である**。
  タイトルは、どの行も太字で表示する。ラベルとタイトルの間隔より、タイトルと最後の発話の間隔を広くする
  (§9。ラベルとタイトルを 1 組にして、最後の発話と区別する。§8.59)
- **Running の行**: daemon の一覧(subscribe)がそのまま行になる。
  **1 行目 = ラベル**(経過時間は、記号と時間の列に表示する)。
  **2 行目**は、waiting の間は `message`(許可内容 / `waitingFor`)、それ以外は会話のタイトル
  (History の行と同じタイトル。`session_id` が一致する search の結果から取得する — §4.6)である。
  タイトルを取得できない間は `task`(最後の依頼文)、それも無ければラベルを表示する(§3.6)。
  **3 行目 = 最後に自分が送った発話**(`task`。`task` に含まれる改行は
  空白に置き換えて、1 行で表示する。
  `task` が無ければ空行にして、行の高さをそろえる)。
  状態記号(記号と時間の列の上): **薄い `✻`(静止)= idle / 輪郭の吹き出し + 太い `!` = waiting /
  グリフ循環スピナー = working**(Claude Code の TUI と同じ `·✢✳✶✻✽` の循環・
  コサインイージング周期 2 秒。「瞬いている Claude」と「静止している Claude」の対。
  ポップオーバーまたはウィンドウを表示している間だけ動作させる)。
  **waiting の状態記号は、オレンジ(`systemOrange`)で表示する**(吹き出しの輪郭と `!` の両方。確認済みかどうかに関係しない)。
  working と idle の状態記号には、色を付けない。
  **未確認 = 状態記号の右肩の、アクセントカラーの点**(明色のフチ付き。トレイの「窓の右肩の点」と同じ文法。タイトルの太さでは示さない)。
  waiting で未確認の行は、オレンジの状態記号と、アクセントカラーの点の両方を表示する。選択中の行(淡い青または淡い灰色の地 — 下記「行の選択」)でも、
  同じ色で表示する(地は淡い色なので、塗りの点とオレンジの記号は判別できる)。色の意味は §3.1。
  **並びは新しいセッション順**(`created_at` の降順)。キーが不変なので、状態が変化しても行は移動しない。
  unreviewed を位置では示さない(§8.31)。`agent_removed` で行を消す。
  対応ターミナル以外で実行しているセッション(target が `process:` — §2)の行も、内容、状態記号、点、並びは同じである
  (違いは、下記「実行のボタン」の Jump だけである)
- **未確認を下ろす操作**(§8.66): Running の行の未確認は、次の操作で下ろす。対応ターミナルのセッションと、それ以外のセッションで、同じ規則である。
  アプリが下ろすときは、`shiibar-cc seen <target>` を実行する(Jump は、CLI が成功時に送る)
  - **利用者が選択した行の選択が、§9 の時間続いたとき**: 利用者の操作で Running の行を選択した時点から計測し、その行の選択が §9 の時間続いた時点で、
    行が未確認であれば下ろす。**選択の時点では下ろさない**(↑ / ↓ で通過しただけの行と、選択してすぐに別の行へ移動した行の点は、残る)。
    計測を開始する選択の操作は、行のクリック、↑ / ↓、選択なしの間の Enter による先頭の行の選択(検索欄と一覧のどちらでも — 下記「キー操作」)、
    詳細ページでの前後の会話への切り替え、通知のクリックによる選択(下記「デスクトップ通知」)である。1 列でも 2 列でも同じである。
    行のドラッグの開始は、Running の行には無い操作なので(ドラッグできるのは Starred と Recent の行 — 下記「行のドラッグ」)、対象に含めない。
    計測は、選択の時点で行が未確認かどうかに関係なく開始し、未確認かどうかは、時間が経過した時点で判定する
    (計測中に未確認になった行は、時間が経過した時点で下りる。時間が経過した後に未確認になった行は、次の操作まで下りない)
  - **選択中の行に対する操作も、選択の操作として扱う**: 次の操作は、計測を最初から開始する。選択を保持している間に未確認になった行は、
    この操作から §9 の時間の後に下りる
    - 選択中の行のクリックのうち、選択が残るもの(灰色で表示している選択中の行のクリック — 一覧にフォーカスを移す。下記「行のクリック」)と、
      選択中の行のダブルクリック(下記「行のダブルクリック」)。青で表示している選択中の行の 1 回のクリックは、選択を解除するので、
      計測を中止する(下記。計測は、クリックの時点で中止する — 選択の解除は、ダブルクリックにならないことが確定するまで待つが、計測の中止は待たない)。
      その行をもう一度クリックして選択すると、計測を開始する。同じ行での 3 回目以降の連続のクリックも、計測を最初から開始する
    - 主ボタンが disabled の Jump である行での Enter(会話を表示する操作 — 下記「行のダブルクリック」。Enter の動作が何も実行しない、1 列の詳細ページを含む)。
      Jump ができる行の Enter は、Jump の成功で下りる
    - ジャンプできないセッションの通知のクリック(下記「デスクトップ通知」の「通知のクリック」。その行が既に選択中で、選択が変化しない場合を含む)
  - **計測の中止**: 選択が別の行に移動したとき、選択が外れたとき(選択の解除と、選択中の行が一覧から無くなったとき — 下記「行の選択」)、
    ポップオーバーまたはウィンドウを閉じたときは、計測を中止する。中止した後は、上記の操作で、最初から計測する(閉じる前の経過時間を引き継がない)。
    ウィンドウが key でなくなっただけでは、中止しない
  - **利用者の操作によらない選択では、計測を開始しない**: ポップオーバーまたはウィンドウを閉じる前から保持している選択 /
    選択を保持したまま行が Running に移ったとき(Resume の後など — 下記「行の選択」)/
    target の付け替え(`rekey`)による選択の引き継ぎ(下記「デスクトップ通知」)。これらの選択と、選択中に応答が完了した場合は、
    選択中の行に点を表示し、上記の操作があるまで下ろさない(画面を見ていない間に、点が消えないようにする)。
    計測中に target が付け替わった場合は、計測を継続し、時間が経過した時点で、新しい target に `seen` を実行する
  - **すぐに下ろす操作**: **Jump の成功**(下記「実行のボタン」。通知のクリックの focus を含む)と、**`Mark all as read`**(下記「⌄ メニュー」)
  - **会話ペインの操作では下ろさない**: 会話ペイン(2 列の右の列、1 列の詳細ページ)の中のクリック、キーの入力、スクロールは、未確認を変更しない
  - **`rekey` の後の再送**: アプリが実行した `seen` の subprocess の開始から終了までの間に、その target の `rekey`(下記「デスクトップ通知」)を
    受信した場合に限り、subprocess の終了の後に、`to` のエントリが未確認であれば、`to` に `seen` を 1 回だけ再送する
    (古い target への `seen` は、何も変更しない — §4.2。この期間の外の `rekey` では、再送しない — 後から立った未確認を下ろさないため)。
    選択が続いた場合の `seen` と、`Mark all as read` の `seen` の、どちらにも適用する(`Mark all as read` は、対象の行ごとの `seen` を、並行して実行する)

  waiting のオレンジは、未確認とは別の情報で、これらの操作では消えない(waiting でなくなった時点で消える — §3.1)
- **実行のボタン**(§8.49): Jump / Resume / Branch は、**下部パネル**(§4.6)にラベル付きのボタンで
  表示する。対象は選択中の行である。行の中には、実行のボタンを配置しない。
  主ボタンは **Jump**(Running の行)または **Resume**(History の行)、副ボタンは **Branch** である。
  **ジャンプできないセッション(target が `process:`、またはアプリが知らない prefix — §4.2)の Running の行では、主ボタンを disabled の Jump にする**
  (理由 `Running in a terminal Shiibar CC can't drive` を、下部パネルに表示する — §4.6「下部パネル」。§8.66)。Branch は押せる。
  下部パネルは、1 列の一覧のページと詳細ページ、2 列の右の列の下端に表示するので、
  画面に表示する実行のボタンは常に 1 組である。行を選択していない間と、検索欄にフォーカスがある間は、
  ボタンを表示しない(§4.6「下部パネル」)。
  ポップオーバーは、実行が成功すると閉じる(上記「ポップオーバー」)。
  - **Jump**: `shiibar-cc focus <target>` を subprocess 実行する(成功時に seen が送られ、未確認が消える)。
    該当なし(exit 2)のときは、エラーを表示しない(ポップオーバーも閉じない) — Running の行は
    subscribe でライブに再生成され、消えたタブの行は reconcile で一覧から除かれる
  - **Resume** / **Branch**: §4.6。Branch は Running の行でも History の行でも押せる
    (実行中の会話の分岐は、その時点までに記録された会話のコピーから始まる — §7-6)。
    Running の行で `session_id` か `cwd` が空のときは Branch を disabled にする。
    Settings の `Terminal` で選択したターミナルを使用できないときは、Resume と Branch を disabled にする(§4.6「Resume と Branch」)
- **詳細ページを開く操作**(§8.59): 1 列で詳細ページを開く操作は、下部パネルの **View** ボタン(§4.6「下部パネル」)と
  → である。対象は選択中の行である。行の中には、詳細ページを開くボタンを配置しない。
  2 列には、この操作が無い(選択中の会話は、右の列に表示している)
- **行の選択**(§8.49): 選択している行は 0 行または 1 行である。選択中の行は、
  **キーの操作対象が一覧である間**は淡い青の地で、それ以外の間は淡い灰色の地で示す(行の全体の地の色を変更する。行ごとの枠は付けない)。
  キーの操作対象が一覧である間とは、その画面(ポップオーバーまたはウィンドウ)が key で、かつ一覧に
  フォーカスがある間(下記「キー操作」)である。検索欄にフォーカスがある間と、ウィンドウが key でない間
  (他のアプリを操作している間など)は、灰色で示す。
  行を選択するのは、利用者の操作(行のクリック・行のドラッグの開始・↑ / ↓・選択なしの間の検索欄の Enter・
  詳細ページでの前後の会話への切り替え・ジャンプできないセッションの通知のクリック — 下記「デスクトップ通知」)だけである
  (検索欄の Enter と同じく、一覧にフォーカスがあり選択なしの間の Enter も、先頭の行を選択する — 下記「キー操作」)。
  グローバルホットキーで開いたときも、行を選択しない(上記「グローバルホットキー」)。アプリの起動後は、
  利用者が行を選択するまで、どの行も選択していない。検索文字列を変更しても、選択中の行が
  検索結果に含まれている間は、選択を変更しない。選択中の Running の行の target が付け替わったとき(reason が `rekey` の `agent_removed` —
  下記「デスクトップ通知」)は、新しい target の行を選択中のままにする(行が無くなったものとして扱わない)。
  選択中の行が一覧から無くなったとき(検索文字列の変更・再取得・セッションの終了・Archive / Unarchive・通常の一覧と Archive の一覧の切り替え — §4.6「Archive」「Archive の一覧」)は、
  選択なしにする(他の行を選択しない)。1 列の詳細ページで表示中の会話が一覧から無くなったときは、
  一覧のページに戻って、選択なしにする。
  **閉じている区画の行は、一覧に表示していない行として扱う**(下記「区画の開閉」。選択の規則では、一覧から無くなった行と同じ扱いにする。
  見出しを表示する条件と空状態では、行として数える — 上記「一覧は 3 つの区画」。History を閉じている間は、Starred と Recent の
  両方を、閉じている区画として扱う): 選択中の行がある区画を閉じたときと、
  選択中の行が、閉じている区画に移動したとき(Resume の後の Running への移動、セッションの終了、スターの変更、
  行のドラッグ)は、選択なしにする(1 列の詳細ページでは、一覧のページに戻る)。
  選択は、Running の行では target、History の行では `session_id` で保持する。
  Running の行が終了して Starred または Recent に移ったときは、`session_id` が同じ行の選択を保持する。
  History の行の会話が Running に移ったとき(Resume の後など)と、Starred と Recent の間を
  移動したとき(スターの変更)も、`session_id` が同じ行の選択と、表示中のページを保持する
  (スターの解除で、会話が Recent の上限を超える位置になった場合は、選択なしにする)。
  選択中の Running の行が消えた時点では、その契機による History の再取得(§4.6)が完了するまで
  選択と詳細ページを変更せず、再取得の結果に同じ `session_id` の行が無いとき(行が、閉じている区画にある場合と、再取得がエラー終了した
  ときを含む)だけ、選択なしにする。再取得が完了するまでの間は、下部パネルのボタンを disabled にし、
  詳細ページのヘッダの位置(`2 / 4`)を表示しない。
  **選択なしの間**は、1 列では詳細ページを開かない。2 列の右の列は、会話ペインのヘッダも下部パネルも
  表示せず、中央に `No conversation selected` の 1 行だけを表示する。
  **選択した行が一覧の表示範囲の外にあるとき**(↑ / ↓ での移動、選択なしの間の Enter による先頭の行の選択、
  詳細ページから一覧のページへ戻ったとき)は、その行の全体が表示範囲に収まる最小の量だけ、一覧をスクロールする。
  同じ操作で一覧の先頭の行を選択したときは、行が表示範囲の中にあっても、一覧を最上部までスクロールする
  (先頭の行の上にある区画の見出しも表示する)
- **行のクリック**: スターと三点リーダー(§4.6)以外の部分をクリックすると、その行を選択する。
  **青で表示している選択中の行をクリックすると、選択を解除する**(選択なしになる)。
  灰色で表示している選択中の行(上記「行の選択」)をクリックしたときは、選択を解除せず、一覧にフォーカスを移す。
  青か灰色かは、マウスのボタンを押した時点の表示で判定する。
  key でないウィンドウの行をクリックしたときは、どの行でも、ウィンドウを key にする。
  クリックでは詳細ページを開かない(上記「詳細ページを開く操作」)。
  2 列では、右の列が選択した会話を表示する。
  どの区画の行にも、ホバーで地の色を変更する表示を付ける(行のドラッグ中は付けない — 下記「行のドラッグ」)。
  Running の行は `session_id` で会話を特定する。`session_id` が空の行も、他の行と同じように選択でき、
  詳細ページを開ける。この行の会話ペインは、ヘッダの 1 行目に行のラベルと経過時間、2 行目に行のタイトルの行(一覧の行の 2 行目)の文字を表示し、
  メッセージ面の中央に `No conversation to show` の 1 行だけを表示する(下部パネルは通常どおり表示する。
  Branch は disabled — 上記「実行のボタン」)
- **行のダブルクリック**: スターと三点リーダー以外の部分をダブルクリックすると、その行を選択し、一覧にフォーカスを移して、
  Jump(Running の行)または Resume(History の行)を実行する。一覧にフォーカスがある間の Enter と同じ動作であり、
  対応するボタンが disabled のときは、選択とフォーカスの移動だけを実行する。
  **ただし、主ボタンが disabled の Jump である行**(ジャンプできないセッションの Running の行と、History に残る live の行 — §4.6)**では、
  Jump の代わりに、その会話を表示する**: 1 列の一覧のページでは詳細ページを開き(View と同じ)、2 列では会話ペインにフォーカスを移す
  (1 列の詳細ページでは、何も実行しない。未確認を下ろす計測は、どのページでも開始する — 上記「未確認を下ろす操作」)。ターミナルへ移動できない行でも、同じ操作で、そのセッションの内容に到達できるようにする(§8.66)。
  選択中の Running の行のセッションが終了し、History の再取得を待っている間の行(ボタンをすべて disabled で表示している状態 — 上記「行の選択」)は、
  この規則の対象にしない(ほかの disabled の行と同じく、選択とフォーカスの移動だけを実行する)。
  行の状態(未選択・青の選択中・灰色の選択中)による違いは無い。
  **⌘ を押しながらダブルクリックすると、Jump / Resume の代わりに Branch を実行する**(一覧にフォーカスがある間の
  ⌘Enter と同じ動作である。§8.59)。⌘ を押しているかどうかは、2 回目のクリックの時点で判定する。
  Branch が disabled のときは、選択とフォーカスの移動だけを実行する。⌘ を押しながらの 1 回のクリックは、
  ⌘ を押していないクリックと同じ動作である。
  **ダブルクリックは、クリックとは別の操作である**: ダブルクリックでは、上記「行のクリック」の動作
  (青で表示している選択中の行の選択の解除)を実行しない。
  そのため、青で表示している選択中の行のクリックによる選択の解除は、ダブルクリックでないことが確定した時点
  (マウスのボタンを押してから、システムのダブルクリックの間隔が経過した時点)で実行する
  (History の行で、その時点でボタンを押したままの場合は、下記「行のドラッグ」の「開始」)。
  **この時点を待っている間に、その行を選択したままにする操作があったときは、選択の解除を取り消す**(操作の直後に、選択が外れないようにする):
  その行のクリック(2 回目以降のクリック、灰色で表示している間のクリック)/ ↑ / ↓ / Enter による行の選択 /
  主ボタンが disabled の Jump である行での Enter(会話を表示する操作)/ その行を選択する通知のクリック(下記「通知のクリック」)/
  キーによる主ボタンまたは Branch の実行(ボタンが disabled で、何も実行しない場合は、取り消さない)/ その行の三点リーダーのメニューを開く操作 / その行のスターの切り替え。
  選択が別の行に移動した場合と、ページが切り替わった場合も、取り消す。検索欄へのフォーカスの移動、ウィンドウの key の変化、ほかの場所の押下では、取り消さない。
  未選択の行の選択と、灰色の行へのフォーカスの移動は、ダブルクリックの結果と一致するので、
  遅らせない。
  待っている間に、選択中の行または表示中のページが変化したとき(↑ / ↓、別の行のクリック、View ボタン、→、
  行が一覧から消えたとき)と、ポップオーバーまたはウィンドウを閉じたときは、選択の解除を取り消す。
  3 回以上の連続したクリックは、3 回目以降で、行の選択と一覧へのフォーカスの移動だけを実行する
  (Jump / Resume を再実行せず、選択も解除しない)
- **区画の開閉**(§8.60): 3 つの区画と History は、見出しのクリックで開閉できる。閉じている区画は、見出しだけを表示し、
  行を表示しない(Recent の `N more` の行 — §4.6 — も表示しない)。
  **History を閉じている間は、History の見出しだけを表示し、Starred と Recent の見出しと行を表示しない**。
  History の開閉と、Starred と Recent の開閉は、別々に記憶する(History を開くと、Starred と Recent を、それぞれについて記憶している状態で表示する)。
  見出しのどこをクリックしても開閉する(帯は、帯の全体がクリックの範囲である。文字と線の見出しは、行の枠の左右の端までの幅の全体が、クリックの範囲である)。
  アニメーションは無い。見出しのクリックから始まる、連続したクリック(ダブルクリックなど)では、最初の 1 回だけ開閉する
  (2 回目以降のクリックは、ポインタの下の要素(見出し、行、行の星、行の三点リーダー)に関係なく、何もしない。開閉によって、ポインタの下の要素が変化する場合があるためである)。
  見出しのクリックは、キーのフォーカスを変更しない(key でないウィンドウの見出しをクリックしたときは、
  ウィンドウを key にして、同じクリックで開閉する)。
  見出しは選択できず、↑ / ↓ の移動の対象にならない。開閉のキー操作は無い。見出しにホバーの表示は付けない。
  - **山形**: 見出しの右端に表示する。開いているときは下向き、閉じているときは右向きである
  - **閉じている見出し**は、名前を二次色で表示する。行数は、開いているときと同じ値を表示する
  - **Running の印**: Running を閉じている間、名前の前に点(大きさは §9)を表示する。waiting の行が 1 つ以上あるときは、
    オレンジの点(waiting の状態記号と同じ色)である。waiting の行が無くて、未確認の行が 1 つ以上あるときは、
    アクセントカラーの点(未確認の点と同じ色)である。トレイアイコンの点と同じ優先順位である(上記「見た目の正」)。
    該当する行が無い間と、Running を開いている間は、表示しない
  - **History の見出しが Recent の見出しを兼ねている間**(Starred に行が無い間 — 上記「一覧は 3 つの区画」):
    History の見出しは、History と Recent の両方が開いているときだけ、開いた状態で表示して、Recent の行を表示する。
    開いた状態の見出しのクリックは、History を閉じる。閉じた状態の見出しのクリックは、History と Recent の両方を開く
  - **Archive の一覧**(§4.6)には、開閉できる見出しが無い(先頭の帯のクリックは、通常の一覧に戻る操作である)。
    記憶している開閉の状態は、Archive の一覧の表示に影響せず、Archive の一覧を表示しても変化しない
  - **状態の記憶**: 閉じているもの(Running、Starred、Recent、History)の集合を UserDefaults に記憶する。ポップオーバーとウィンドウで共通で、
    アプリを再起動しても保持する。既定は、すべて開いた状態である。表示していない見出しの状態も保持する。
    保存済みの値が想定の形でない場合と、この 4 つの名前でない値は、無視する
  - **閉じている区画の行は、一覧に表示していない行である**: ↑ / ↓ の移動、「一覧の先頭の行」の選択
    (選択なしの間の Enter)、詳細ページの位置(`2 / 4`)と前後の会話への切り替えは、
    表示している行だけを対象にする(「一覧の先頭の行」は、表示している最初の行である)。選択の扱いは、上記「行の選択」。
    表示している行が 1 つも無いとき(行のある区画をすべて閉じているとき)は、これらの操作では、
    行が 1 つも無いときと同じ扱いにする(選択なしの間の Enter は何もしない。ホットキーは検索欄にフォーカスを移す)
  - **検索中**(クエリが有効な間 — §4.6「検索の適用範囲」。検索文字列が有効になった時点から、search の結果を
    受け取る前と、search がエラー終了した場合を含む。検索文字列が有効でなくなった時点で終了する): Running、Starred、Recent、History のどれも、記憶している状態に関係なく、
    開いているものとして扱う。Starred と Recent の見出しは表示せず、History の見出しの下に、Starred の行と Recent の行を、
    1 つの枠の中に続けて表示する(§4.6「検索の適用範囲」)。Running と History の見出しは、帯の形のままで、
    山形と Running の印を表示しない。見出しをクリックしても開閉しない(key でないウィンドウの見出しをクリックしたときは、ウィンドウを key にする)。
    記憶している状態は変更せず、検索を終えると、記憶している状態の表示に戻る
    (この時点で、選択中の行が、閉じている区画にある場合は、選択なしにする)
- **行のドラッグ**(§8.60): 通常の一覧の History の行は、ドラッグで移動できる(Archive の一覧の行は、ドラッグできない。理由の表示も無い — §4.6「Archive の一覧」)。Starred の中の移動は順序の変更、
  Recent から Starred への移動はスターの追加、Starred から Recent への移動はスターの解除である(スターは §4.6)。
  ドラッグは、アプリの中だけの操作である(システムのドラッグ アンド ドロップとペーストボードを使用しない。
  ほかのアプリにはドロップできない)。
  - **ドラッグできない行**: 次の行では、ドラッグを開始しない — Running の行 / **検索中の、すべての行** /
    Starred に行が無い間(Starred の見出しを表示していない間)の、Recent の行(移動先が無い。スターは、星のクリックで付ける)。
    これらの行の上(スターと三点リーダーを除く)でマウスのボタンを押し、押した位置から §9 の距離以上を移動した時点で、
    ポインタの近くに、理由を 1 行で表示する(ポップオーバーまたはウィンドウの中に収める。形と位置は `docs/window-design.html`。§9 の時間の後に消去する。次にマウスのボタンを押した時点でも消去する。
    1 回の押下で表示するのは 1 回で、表示した後は、ポインタに追従しない)。
    文言は、Running の行では `Running is ordered automatically`、検索中は `Clear the search to reorder`、
    Starred に行が無い間の Recent の行では `Click the star to add it to Starred` である。
    複数に該当する行では、Running の行、検索中、Starred に行が無い間の Recent の行の順に、最初に該当した文言を表示する。
    ダブルクリックの 2 回目以降の押下では、表示しない。
    この押下の、クリックとダブルクリックとしての動作は、変更しない
  - **開始**: 行の上(スターと三点リーダーを除く)でマウスのボタンを押し、押した位置から §9 の距離以上を移動した時点で開始する。
    長押しは不要である。ダブルクリックの 2 回目以降の押下からは開始しない。
    ドラッグを開始した時点で、クリックと同じ選択とフォーカスの移動(未選択の行の選択、一覧へのフォーカスの移動)を実行する。
    key でないウィンドウの行を押した場合も、同じ押下でドラッグを開始できる。
    ドラッグを開始した押下は、クリックとして扱わない(ボタンを離した時点で、クリックとダブルクリックの動作を実行しない)。
    **History の行で、青で表示している選択中の行を押した場合は、ボタンを押している間、選択の解除(上記「行のダブルクリック」)を
    実行しない**: ダブルクリックの間隔が経過した時点でボタンを押したままのときは、ボタンを離した時点で、選択を解除する。
    ボタンを離す前にドラッグを開始したときは、選択を解除しない
  - **ドラッグ中の表示**: 行の画像(角丸の枠と影を付ける。選択中の地の色は付けない。不透明度は §9)が、押した位置との相対位置を保って、ポインタに追従する。
    元の行は、その場に残して薄く表示する(§9)。ほかの行は移動しない。カーソルは変更しない。
    **挿入位置にならない行**(Running と Recent の行。ドラッグ中の行を除く)は、薄く表示する(§9)。Recent の `N more` の行は、薄くしない。
    **ドラッグ中は、どの行にも、ホバーの表示を付けない**(地の色の変更と、Recent の行の輪郭だけの星 — §4.6「スター」)。
    **見出しの案内**: Recent の行のドラッグ中は Starred の見出しに `Drop here to star` を、Starred の行のドラッグ中は
    Recent の見出しに `Drop here to unstar` を、山形の左に表示する(行数と同じ文字の大きさで、アクセントカラーである。
    ドラッグの開始から終了まで表示する。見出しを閉じている間も表示する)
  - **移動先**は、ポインタが一覧の表示範囲の中にある間、ポインタの上下の位置で決まる(一覧の中の左右の余白にある場合も、同じ高さにある要素の位置として扱う)。
    ポインタが一覧の表示範囲の外(上下または左右)にある間は、移動先なしである。

    | ポインタの位置 | ドラッグ元 | 移動先 | 表示 |
    |---|---|---|---|
    | Starred の行の上半分 | Starred / Recent | その行の直前 | その行の上の線 |
    | Starred の行の下半分 | Starred / Recent | 次の行の直前(最後の行では、末尾) | その行の下の線 |
    | 開いている Starred の見出し | Starred / Recent | 先頭 | 最初の行の上の線 |
    | 閉じている Starred の見出し | Recent | 末尾 | Starred の見出しの強調 |
    | Recent の区画(見出し、行、`N more` の行) | Starred | スターの解除 | Recent の見出しの強調 |
    | Recent の区画 | Recent | なし | なし |
    | それ以外(Running の区画、History の見出し、一覧の表示範囲の外) | Starred / Recent | なし | なし |

    **要素の間の隙間と、一覧の端**: Starred の見出しと行の枠の間の隙間と、Starred の区画の最後の要素(行の枠、または閉じている見出し)と
    Recent の見出しの間の隙間では、直前の移動先を保持する。Recent の区画の中の隙間は、Recent の区画として扱う。
    Running の区画の中の隙間と、Running の区画の最後の要素と History の見出しの間の隙間は、Running の区画として扱う。
    History の見出しと Starred の見出しの間の隙間は、History の見出しとして扱う。一覧の最初の要素より上は、最初の要素の位置として扱い、
    最後の要素より下は、最後の要素の下半分の位置として扱う(ポインタが一覧の表示範囲の中にある場合)。
    Starred の先頭への移動は、表示している最初の行の直前への移動である。
    線は、並びが変化しない位置(ドラッグ中の行の前後)でも表示する。
    ドラッグ中に、一覧の内容または配置が変化したとき(Running の行の増減、再取得、スクロール)は、ポインタの位置から
    移動先を再計算する。隙間で保持している移動先の行が無くなったときは、移動先なしにする。
    **線を表示している間は、線の位置が、ドロップで配置する位置である**(一覧の内容が変化した直後も同じである)。
    線は、アクセントカラーの太さ 2pt の線で、左端に輪を付ける。行と行の間の線は、区切り線の位置に表示する。
    見出しの強調は、選択中の行と同じ淡い青の地と、アクセントカラーの 2pt の枠である(強調の範囲は、行の枠の左右の端までの幅で、角を丸める。
    強調している間も、見出しの線は表示する。形は `docs/window-design.html`)。
    Recent の行のドラッグ中に、移動先を線で示している間は、Starred の行の枠も、アクセントカラーの 2pt の枠で強調する。
    Recent の中の位置は新しい順で決まるので(§4.6「Recent の区画」)、Recent への移動では、位置を示す線を表示しない。
    Recent に行が無い間(Recent の見出しを表示していない間)は、Starred の行のスターを、ドラッグでは解除できない
  - **ドロップ**: 移動先がある状態でボタンを離すと、移動を実行する。アニメーションは無い。
    Starred への移動は、スターの順序付きの一覧(§4.6「スター」)の中で、移動する行を、移動先の行の直前に
    配置する(末尾への移動は、一覧の末尾に配置する)。移動する行以外の会話(Starred に表示していない、Running にある会話を含む)の、
    相互の順序は変更しない。表示している Starred の行の順序が変化しないドロップ(同じ位置へのドロップ)は、スターの一覧を変更しない(保存もしない)。
    移動した行の選択は保持する(移動先が閉じている区画のときは、上記「行の選択」のとおり、選択なしにする)
  - **取り消し**: 次の場合は、スターとその順序を変更せずにドラッグを終了する(ドラッグの開始で実行した選択とフォーカスの移動は、元に戻さない)— 移動先が無い状態でボタンを離したとき / Esc を押したとき /
    ボタンを離したイベントを受信しないまま、ボタンが離れた状態が、§9 の時間続いたとき(ボタンを離したイベントは、ボタンの状態の変化より後に届く場合があるので、
    離れた状態を検出した時点では取り消さない。離れた状態を検出している間は、自動スクロールしない)/ ボタンを離したイベントを受信しないまま、次にボタンを押したとき /
    ポップオーバーまたはウィンドウを閉じたとき(アプリが非アクティブになってポップオーバーを閉じる場合を含む)/
    ポップオーバーまたはウィンドウが key でなくなったとき / 検索を開始したとき / ドラッグ中の行が、ドラッグを開始した区画の
    表示している行から無くなったとき(Running への移動、再取得、Recent の上限を超える位置への移動)。
    **ドラッグ中の Esc は、ドラッグの取り消しだけを実行する**(ポップオーバーを閉じない)。
    ドラッグ中は、Esc 以外のキー(下記「キー操作」の表のキー)を処理しない
  - **自動スクロール**: ドラッグ中に、ポインタが一覧の上端または下端の近く(§9)にある間、一覧をその方向に
    スクロールする。ポインタが一覧の上端より上、または下端より下にある間も、最高の速さ(§9)でスクロールを続ける
    (ポインタの左右の位置は条件にしない)。スクロールに合わせて、移動先を更新する
- **キー操作**(§8.49): ポップオーバーとウィンドウは、次のキーを、フォーカスのあるビューより先に処理する。
  キーの動作は、**検索欄にフォーカスがあるかどうか**で 2 通りに分かれる。検索欄では文字の編集だけを行い、
  行の操作は一覧で行う。「一覧にフォーカスがある」は、検索欄にフォーカスが無い状態を指す
  (詳細ページと、会話ペインにフォーカスがある場合を含む)。
  検索欄にフォーカスがある間は、検索欄にカーソルを表示する。一覧にフォーカスがある間は、カーソルを表示しない。

  | キー | 検索欄にフォーカスがある間 | 一覧にフォーカスがある間 |
  |---|---|---|
  | 文字の入力 / Delete | 検索欄に入力する(標準の動作) | 何もしない |
  | ← / → | 検索欄のカーソルを移動する(標準の動作) | → は、1 列の一覧のページで、選択中の行の詳細ページを開く(下部パネルの View と同じ。選択なしの間は何もしない)。← は、1 列の詳細ページで一覧のページに戻る。それ以外では何もしない |
  | ↑ / ↓ | 何もしない | 前後の行に選択を移動する(区画をまたいで移動する。閉じている区画の行は対象にしない — 上記「区画の開閉」。端では移動しない)。選択なしの間は、どちらのキーも一覧の先頭の行を選択する。検索中は検索結果の行だけを移動する。1 列の詳細ページでは、会話をスクロールする(会話ペインの標準の動作。Space と Page Up / Page Down も同じ) |
  | ⌥↑ / ⌥↓ | 検索欄のカーソルを移動する(標準の動作) | 1 列の詳細ページで、表示する会話を前後の行の会話に切り替える(選択も移動する。スライドはしない。端では何もしない)。それ以外では何もしない |
  | Enter | 一覧にフォーカスを移す。選択なしの間は、一覧の先頭の行を選択する。行が 1 つも無いときは何もしない | 選択中の行の Jump または Resume を実行する(下部パネルの主ボタンと同じ)。どのページでも同じ。選択なしの間は、一覧の先頭の行を選択する(検索欄の Enter と同じ。行が 1 つも無いときは何もしない)。主ボタンが disabled の Jump である行では、会話を表示する(1 列の一覧のページでは詳細ページを開き、2 列では会話ペインにフォーカスを移す — 上記「行のダブルクリック」) |
  | ⌘Enter | 何もしない | 選択中の行の Branch を実行する(下部パネルの Branch と同じ)。どのページでも同じ |
  | ⌘G / ⇧⌘G | 会話内の次のヒット / 前のヒットに移動する(§4.6「ヒットナビゲーション」)。会話ペインを表示している間だけ有効 | 同じ |
  | ⌘F | 何もしない | 検索欄にフォーカスを移す。1 列の詳細ページでは、一覧のページに戻ってから移す |
  | ⌘R | Refresh を実行する(見出し行の Refresh のボタンと同じ。§4.6)。どのページでも同じ | 同じ |
  | ⌘= / ⌘+ / ⌘− / ⌘0 | 文字の大きさを変更する(下記「文字の大きさ」)。どのページでも同じ | 同じ |
  | Esc | ポップオーバーを閉じる。ウィンドウでは何もしない。行のドラッグ中は、ドラッグの取り消しだけを実行する(上記「行のドラッグ」)。Archive の一覧を表示している間は、通常の一覧に戻る操作だけを実行する(ポップオーバーを閉じない。§4.6「Archive の一覧」) | 同じ。どのページでも同じ |

  **一覧にフォーカスを移す操作**は、検索欄での Enter と、行のクリックと、行のドラッグの開始である。
  **検索欄にフォーカスを移す操作**は、検索欄のクリック(消去のボタンを含む)と ⌘F である。
  ポップオーバーを開いたときのフォーカスは、上記「ポップオーバー」のとおりである。
  Tab と ⇧Tab は標準のフォーカスの移動である。**1 列の詳細ページを表示している間は、一覧のページのビュー(検索欄など)を、
  Tab と ⇧Tab の移動先にしない**(詳細ページの下に残っている、表示していないビューに、フォーカスを移さない。§8.59)。対応するボタンが disabled のとき、
  一覧にフォーカスがある間の Enter と ⌘Enter は何もしない(主ボタンが disabled の Jump である行の Enter を除く — 上記の表)。
  選択なしの間は、⌘Enter は何もせず、Enter は先頭の行を選択する(上記の表)。
  **日本語入力の変換が未確定(marked text)の間は、すべてのキーを日本語入力に渡す**
  (変換の確定の Enter と、候補の選択の ↑ / ↓ を横取りしない)
- **クリックスルー**: ウィンドウにフォーカスが無い状態でも、行・区画の見出し・下部パネルのボタンは
  1 クリック目で反応する(状態を確認してすぐ Jump するための画面なので、前面化のためだけのクリックを要求しない)
- **ピン(Keep on Top)**: ウィンドウの見出し行のピンのボタン(`Open in popover` の右。上記「見出し行」)。アイコンは、斜めに傾いた画びょうである
  (形は `docs/window-design.html`)。ON は、アイコンがアクセントカラーの塗りで、ボタンの背景が
  アクセントカラーの 16%(押している間は 24%。ホバーでは変更しない)である。OFF は、二次色の輪郭だけである。
  既定は OFF。ON の間だけウィンドウを最前面(floating レベル)に保つ。**変更するのはウィンドウレベルだけ** —
  全 Space への追従はしない、フォーカスも奪わない(クリックスルーと組み合わせると、最前面の一覧を
  確認しながらターミナルで作業し、そのまま Jump できる)。値は UserDefaults に永続し、
  押した直後に反映する(§8.33 / §8.49)。ポップオーバーにピンは無い。
  **ピンが ON で、ウィンドウを開いている間は、Settings ウィンドウと About パネルも floating レベルにする**(§8.62)。
  これらのウィンドウを開いたときに、ピンが ON のウィンドウより手前に表示するためである。ピンを切り替えたときと、ウィンドウを開いたとき、閉じたときに、
  開いているこれらのウィンドウのレベルも、すぐに切り替える。ピンが OFF の間と、ウィンドウを閉じている間(ポップオーバーの形で使用している間を含む)は、
  通常のレベルである(ウィンドウを最小化している間は、開いている間に含む)。開く経路(ポップオーバーとウィンドウの ⌄ メニュー、アプリメニュー、⌘,)に関係なく適用する
- **⌄ メニュー**(見出し行の右端): **About Shiibar CC**(標準の About パネル =
  `orderFrontStandardAboutPanel`。アイコン・名前・バージョンは bundle から自動)/ セパレーター /
  **Settings…**(下記・§8.26。Setup Check は、Settings ウィンドウのタブである)/ セパレーター /
  **Archived**(Archive の一覧を表示する。Archive した会話が 1 つも無い間は disabled。Archive の一覧を表示している間は、
  項目にチェックマークを付け、選択すると通常の一覧に戻る — §4.6「Archive の一覧」)/
  **Mark all as read**(全セッションの unreviewed フラグを消す。未読が 1 つも無ければ disabled。
  消えるのは、未確認の点(アクセントカラー)だけである。waiting のオレンジは、そのセッションが waiting でなくなるまで残る(§3.1)。
  通知センターの配信済み通知は**変更しない**(§8.24 — 通知は利用者が自分で消す)。
  実装は未読 target ごとに `shiibar-cc seen <target>` を呼ぶ)/ セパレーター / **Quit**。
  UI 文言は英語。
  **メニューには、画面のほかの場所で提供していない操作だけを含める**(§8.54)。Refresh は、見出し行のボタンで提供するので、
  メニューに含めない(§8.62)。Archive の一覧は、普段は表示する必要が無く、Archive した会話は増え続けるので、
  見出し行のボタンではなく、メニューの項目で開く(§8.63)
- **メニューバーのメニューはアプリメニューと Edit メニューの 2 個**(File / Format / View / Window / Help は
  表示しない)。Edit は標準項目のみ(Undo ⌘Z / Redo ⇧⌘Z / 区切り / Cut ⌘X / Copy ⌘C /
  Paste ⌘V / Select All ⌘A) — テキスト欄(検索欄・Settings)や会話ペインで標準ショートカットを
  配達するために必要(メニュー項目が無い ⌘V 等は macOS では配達されない。§8.41)。
  システムが Edit に注入する項目のうち **Start Dictation / Emoji & Symbols は標準の抑止設定で
  表示しない**。**Delete / AutoFill は受け入れる**(SwiftUI がメニューを所有し、開くたびに再生成する
  ため、公認の手段では消せない — §8.42)。
  アプリメニューの構成:
  About Shiibar CC / セパレーター / Settings…(⌘,)/ セパレーター /
  Close Window(⌘W。key ウィンドウを閉じる標準動作。ポップオーバーが key の間は、ポップオーバーを閉じる。
  **閉じられるウィンドウが無ければ disabled**)/
  セパレーター / Quit Shiibar CC(⌘Q)。
  アプリメニューの項目は、macOS のアプリの決まった場所にある項目だけである(Archived、Mark all as read は
  ⌄ メニューに、Refresh は見出し行にある。アプリメニューは、アプリが通常アプリである間だけ表示される — 上記「ウィンドウを開いている間だけ」の
  項目)。
  Close Window を除き、各項目の挙動は ⌄ メニューの同名項目と同一。
  メニューの Quit は ⌄ の Quit と同じ終了処理(daemon の shutdown ack を待つ処理)を通す
- **固定フッター**: 一覧の下(スクロールに含めない位置)に、上から警告行(下記「異常の可視化」)、
  **メッセージ行**、**キーの案内**を配置する。1 列では、キーの案内の段が下部パネル(§4.6)になる。
  - **メッセージ行**: 表示する内容があるときだけ表示する 1 行である。索引の進捗・エラー・
    Refresh の一時表示(`Refreshing…` / `✓ Refresh done` / `Refresh failed`。§4.6。
    表示時間は §9)を表示する(表示の優先順位は §4.6「メッセージ行」)
  - **キーの案内**: 常に表示する 1 行で、その時点で使用できる移動のキーを示す(上記「キー操作」)。
    **検索欄にフォーカスがある間**は、1 列でも 2 列でも `↩ List` だけを表示する。
    **一覧にフォーカスがある間**は、1 列の一覧のページも 2 列も `↑↓ Move` を表示する。
    実行のキー(Enter と ⌘Enter)と、詳細ページを開くキー(→)は、下部パネルのボタンの中に表示する(§4.6)。
    1 列では、キーの案内を下部パネルの左側に配置する(一覧のページと詳細ページの両方。§4.6)。
    2 列では、左の列のフッターにキーの案内だけを表示する(実行のボタンは右の列の下部パネルにある)
  - **1 列の詳細ページ**では、警告行とメッセージ行を、会話ペインの下部パネルのすぐ上に表示する
    (詳細ページを表示している間に発生した切断や TCC エラーを、一覧に戻らなくても確認できるようにする)
- **表示中の更新**: スピナーは、ポップオーバーまたはウィンドウを表示している間だけ動作させる。
  スピナーのグリフの切り替えは、Core Animation のアニメーションで実行する(切り替えのたびに、アプリの
  メインスレッドで表示を更新しない。§8.57)。切り替えの時刻は §9 の計算式で決まり、
  複数の行のスピナーは、同じ時刻に同じグリフを表示する(周期の開始の時刻は、行を表示した時刻ではなく、すべての行に共通の時計の時刻のうち、周期(§9)の整数倍の時刻にする。
  後から表示した行も、同じ時刻に同じグリフを表示する)。
  経過時間の基準は、表示した時点で再取得したうえで、**表示中は毎分再取得する**(表示が分粒度なので
  毎秒の更新は不要)。タイマーも、表示している間だけ動作させる。通知許可の denied 判定も、
  ポップオーバーまたはウィンドウを表示するたびに再評価する
- **Settings ウィンドウ**(⌄ → Settings…): 設定と、導入の状態の確認(Setup Check)をまとめる独立ウィンドウ。
  表示時に `NSApp.activate`(accessory の状態では、これが無いと、ウィンドウがほかのアプリの後ろに開く)。**閉じるボタンは置かない**(全項目が、選んだ時点または入力を確定した時点で反映され、
  「OK で確定」が無いため。閉じるのはタイトルバーの赤ボタンと ⌘W。§8.26)。
  値はすべて UserDefaults に永続。UI 文言は英語。
  **タブは 2 つ**で、左から `General`(設定)、`Setup Check`(導入の状態の確認 — 下記「Setup Check のタブ」)である。
  General のタブの構成は、見出し付きの枠が 2 つ(General と Sounds)で、General の枠は Start at Login / Appearance / Text size / Global shortcut / Terminal の順である。
  - **タブの行**: ウィンドウの上端(タイトルバーの下)に、タブのボタンを中央にそろえて並べ、行の下に 1pt の線(`separatorColor`)を引く。
    ボタンは、上にアイコン(18pt)、下に名前(11pt)で、選択中のタブは、アクセントカラーを不透明度 0.16 で重ねた角丸の地と、アクセントカラーのアイコンと文字で示す。
    選択していないタブは、地が無く、アイコンと文字は `labelColor` である(寸法は §9)。アイコンは、General が歯車、Setup Check がチェックの一覧の SF Symbols である
  - **開いたときのタブ**: Settings ウィンドウを開くたびに、`General` を表示する(前回のタブを記憶しない)。ウィンドウを開いている間に、もう一度 Settings… を
    選択したときは、タブを変更せずに、ウィンドウを前面に表示する
  - **タブの切り替え**は、タブのボタンのクリックだけである(キー操作は無い。タブのボタンは、キーのフォーカスを受け取らない)。
    切り替えたときに、ウィンドウの高さを、表示するタブの内容に合わせる(上端と左端の位置を保つ)。General のタブで入力の途中の値
    (Text size の入力欄)は、タブを切り替えた時点で、フォーカスが外れたときと同じ規則で扱う(下記)。Global shortcut の記録中にタブを切り替えたときは、記録を中止する
  **見た目の規則**(§8.65。寸法は §9):
  - **1 行 = 左にラベルと 1 行の説明、右にコントロール 1 つ**。ラベルは 13pt のセミボールド、説明は 11pt の二次色
    (`secondaryLabelColor`)で、ラベルの下に表示する。すべての行に説明を付ける(その設定で何が起きるかを、操作する前に読めるようにする)。
    入力のエラーと案内の文字は、11pt の固定の色(§9)で、説明の下に表示する(右の列には表示しない)
  - **右の列は幅が固定**(§9)で、コントロールを右端にそろえる。行によってコントロールの位置が変化しない
  - **枠**: すべての枠に見出しを付ける(12pt のセミボールド)。枠は、角丸の地と 1pt の枠線(`separatorColor`)で、
    地は、一覧の行の枠の地と同じ色である(window-design.html「実装ノート」)。行の間に 1pt の線(`separatorColor`)を引く。
    ウィンドウの地は `windowBackgroundColor` である
  - **コントロールの種類**: スイッチ(ON / OFF)、セグメント(2〜3 択で、1 行に収まるとき)、ポップアップ(4 択以上、または選択肢が長いとき)、
    数値の入力欄とステッパー(Text size)、キーの組み合わせの欄(Global shortcut)。スイッチは小さいサイズ(`controlSize(.small)`)にする
  - **ウィンドウの大きさ**: 幅は、どのタブでも同じ固定の値(§9)で、高さは、表示しているタブの内容に合わせる(スクロールしない。エラーまたは案内の行を表示したとき、
    Setup Check の行の数と行の折り返しが変化したときは、その分だけ高さが変化する)

  各行のラベル、説明、コントロールは、次のとおりである:

  | 枠 | ラベル | 説明 | コントロール |
  | --- | --- | --- | --- |
  | General | `Start at Login` | `Runs in the menu bar after you log in to your Mac` | スイッチ |
  | General | `Appearance` | `System follows the appearance setting of your Mac` | セグメント(System / Light / Dark) |
  | General | `Text size` | `Text in the popover and the window` | 数値の入力欄とステッパー |
  | General | `Global shortcut` | `Shows the list from any app` | キーの組み合わせの欄 |
  | General | `Terminal` | `Resume and Branch open in this terminal` | セグメント(iTerm2 / Terminal / Ghostty) |
  | Sounds | `Mute sound` | `Notifications arrive silently` | スイッチ |
  | Sounds | `Waiting sound` | `Plays when a session needs your input` | ポップアップ |
  | Sounds | `Done sound` | `Plays when a session finishes responding` | ポップアップ |

  各項目の動作は、次のとおりである:
  - **General**: Start at Login(スイッチ。`SMAppService` の状態を直接読み書きする)/
    **Appearance**(セグメント: System / Light / Dark。既定 System = OS に従う。
    アプリ全体の外観(`NSApp.appearance`)を選んだ瞬間に切り替え、UserDefaults 永続・起動時に再適用。
    ポップオーバー・ウィンドウ・Settings が一括で従う。
    トレイアイコンはテンプレート画像なのでメニューバー側の外観に従い続ける。§8.30)/
    **Global shortcut**(キーの組み合わせを記録する欄。上記「グローバルホットキー」のキーを登録する。
    未登録の間は `Record Shortcut` を表示する。欄をクリックすると記録中になり、`Type shortcut` を表示する。
    記録中に押したキーの組み合わせを、その時点で登録して UserDefaults に保存し、記録を終了する。
    登録済みの間は、組み合わせを修飾キーの記号とキーの名前で表示し(例: `⌃⌥Space`、`⇧⌘K`)、
    右端に登録を解除する × ボタンを表示する。
    **修飾キーは ⌃ / ⌥ / ⇧ / ⌘ の任意の組み合わせを登録できる**。ただし、⌃ / ⌥ / ⌘ のいずれかを含まない
    組み合わせ(修飾キーなし、または ⇧ だけ)は、ファンクションキー(F1〜F20)の場合だけ登録できる
    (文字の入力に使用するキーを、すべてのアプリで入力できなくなるため)。
    登録できない組み合わせを押したときは、記録中のまま、説明の下に
    `Add ⌃, ⌥, or ⌘ to the shortcut` を表示する。
    システムが登録を拒否したときは、記録を終了して以前の登録を保持し、
    説明の下に `This shortcut is already in use` を表示する
    (他のアプリが同じ組み合わせを登録している場合、システムは登録を拒否しない。
    その場合にどちらのアプリが受け取るかは、システムが決める)。
    説明の下の案内は、次に記録を開始したとき、登録に成功したとき、記録を中止したときに消去する。
    記録中の Esc(修飾キーの有無に関係しない)、欄の外のクリック、Settings ウィンドウが key でなくなったときは、
    記録を中止して以前の登録を保持する。記録中は × ボタンを表示しない。
    キーの名前は、記録した時点のキーボード配列での文字を保存して表示する。
    文字を持たないキーは、`Space`、`F1`〜`F20`、メニューで使用する記号(↩ ⇥ ⌫ ⌦ と矢印など)で表示する。
    起動時の登録に失敗した場合は、保存した値を保持したまま、欄に `Record Shortcut` を表示する)
  - **General** の **Terminal**(§8.66): Resume と Branch で、新しいウィンドウを開くターミナルを選択する(§4.6「Resume と Branch」)。
    この設定が決めるのは、Resume と Branch を開く先だけである(Jump は、セッションを実行しているターミナルへ移動する操作で、この設定に関係しない)。
    3 つの選択肢は、インストールの有無に関係なく、常に選択できる。値は UserDefaults に保存し(§9)、選んだ時点で反映する。
    **選択したターミナルを使用できないとき**(アプリがインストールされていない。Ghostty は、インストールされているバージョンが §9 の最小のバージョン未満の場合を含む)は、
    説明の下に、エラーと案内の文字の色(§9)で、理由を 1 行表示する — `iTerm2 is not installed` / `Ghostty is not installed` /
    `Ghostty 1.4.0 or later is required`(Terminal は macOS に含まれるので、この表示は無い)。インストールの有無とバージョンは、
    バンドル ID(§9)で検索したアプリのバンドルの情報(`CFBundleShortVersionString`。バージョンの解釈は、§4.1 の `TERM_PROGRAM_VERSION` と同じ規則。
    Ghostty のバンドルにこの値が無い場合と、値を解釈できない場合は、最小のバージョン未満として扱う)で判定する(AppleScript は使用しない。ターミナルを起動しない)。
    判定は、Settings ウィンドウを表示したとき、ポップオーバーまたはウィンドウを表示したとき、アプリがアクティブになったときに、再度実行する
    (ウィンドウを表示したままターミナルをインストールした場合にも、アプリに戻った時点で反映する)。
    インストールされている Ghostty が最小のバージョン以上で、起動中の Ghostty が古い場合(更新の後に再起動していない場合)は、この判定では検出しない。
    Resume または Branch の実行が失敗し(CLI の exit 1 — §4.4)、メッセージ行にエラーを表示する(§4.6「メッセージ行」)。
    **最初の値**は、アプリの起動時に、値が保存されていない場合に 1 回だけ決めて保存する。次の順である: UserDefaults に `cc.shiibar.lastObservedTerminal` の値がある場合
    (保存形式の 1 回の移行 — §8.66。値が `iterm2` または `apple-terminal` の場合に、その値にする。このキーは、アプリの起動時に、
    この設定の値が保存済みかどうかに関係なく、削除する)
    → iTerm2 がインストールされていれば iTerm2 → Terminal。保存されている値が 3 つの選択肢のどれでもない場合は、保存されていない場合と同じに扱う。
    Ghostty は、最初の値にしない(Ghostty と Terminal だけがインストールされている場合は Terminal になる。Ghostty は最小のバージョンの条件があるので、利用者が選択する)
  - **General** の **Text size**: 数値の入力欄(幅 56pt・右寄せ)と、macOS 標準の
    ステッパー(1 ずつ変更。入力欄との間隔は 4pt)。値と適用する範囲は、
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
  - **Sounds**: Mute sound(スイッチ)/
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
  トレイアイコン、Settings ウィンドウ、メニュー、ツールチップには適用しない。
  `docs/window-design.html` の寸法は、文字の大きさが 13 のときの値である。
  - **13 に対する比率で連動する寸法**: すべての文字の大きさ(ボタンの中のキーの記号を含む)、行の高さ、
    上下の余白と上下の間隔、アイコンと記号とその枠(行の状態記号と未確認の点、スター、三点リーダー、区画の見出しの山形と Running の印、Archive の一覧の帯の `‹`、虫眼鏡、
    消去のボタン、前後の会話に切り替えるボタン。アイコンの線の太さを含む)、行の記号と時間の列の幅、
    見出し行のボタン(Refresh、`Open in window`、`Open in popover`、ピン、⌄)と会話ペインのヘッダの戻るボタンの大きさ(13 のとき 24pt)と、
    そのアイコン(13 のとき 15pt。線の太さを含む)、検索欄の高さ、ドラッグ中の自動スクロールの範囲(§9)、主ボタンの最小の幅
    (左右の寸法であるが、ラベルの文字に合わせて連動する)、見出しの帯の高さ(上端と下端の線の太さを除く)。比率を掛けた値は丸めない
    (丸めるのは、下記のポップオーバーの幅と一覧の列の既定の幅だけである)。
  - **固定の寸法**: 左右の余白と左右の間隔(スターの枠と三点リーダーの枠の間隔を含む)、角の半径、枠線の太さ、見出しの帯の上端と下端の線の太さ、帯の上と下の間隔(§9)、行のドラッグの移動先の線と輪と強調の枠、行のドラッグの開始の距離と自動スクロールの速さ(§9)、ドラッグできない理由の表示のポインタからの距離、見出し行のボタンと戻るボタンのホバーの地の角の半径と、ボタンの左右の間隔(8pt)、
    会話ペインのミニマップの幅と、その手前の折り返しの余白、ポップオーバーの下端のドラッグ領域、
    OS が描画する部品(ウィンドウの信号機ボタン、検索バー行と見出し行の ‹ › のセグメント)。
  - **見出し行の高さ**は、ポップオーバーでは、検索欄の高さと見出し行のボタンの高さの大きいほうに、上下の余白(連動)を
    加えた値である。検索欄とボタンは、上下の中心をそろえる。
    ウィンドウの見出し行(1 列、2 列とも)は、検索欄の高さとボタンの高さの大きいほうを内容の高さにし、内容の上下の中心を
    信号機ボタンの中心にそろえて、上と下の余白を同じ値にする(下記「ウィンドウ」)。
    2 列の右の列の会話ペインのヘッダは、見出し行の区切り線の下に、
    上の余白 11pt、下の余白 8pt(文字の大きさ 13 のとき。比率で連動する)で配置する。
  - **幅が不足する場合**: 下部パネルは、ボタンを優先して表示する。キーの案内は、残りの幅に全体が
    収まる項目だけを、先頭から表示する(項目の途中で切らない)。行の文字は、末尾を省略して 1 行で表示する(文字の大きさ 13 のときと同じ規則)。
  - **ポップオーバーの幅**は、比率で連動する(13 のとき 420pt。小数点以下は四捨五入する)。
    表示している間に文字の大きさを変更した場合も、その時点で幅を変更する。高さ(記憶した高さ、
    初回の高さ、最小の高さ、初回の高さに固定する範囲)は、文字の大きさで変更しない。
  - **ウィンドウ**は、記憶した大きさと最小の大きさを変更せず、内容だけを連動させる。
    2 列のときの一覧の列の既定の幅は、ポップオーバーの幅と同じ値で連動する(列の境界のドラッグで
    記憶した幅がある間は、記憶した幅を使用する — 上記「幅による切り替え」)。2 列になる幅(§9)は、
    文字の大きさで変化しない(文字の大きさを変更しても、列の数は変化しない)。
    ウィンドウの見出し行と、ウィンドウの 1 列の詳細ページのヘッダは、内容の高さが変化しても、内容の上下の中心を
    信号機ボタンの中心(ウィンドウの上端から 26pt)にそろえ、下の余白を、上の余白と同じ値にする。
    行の領域は、信号機ボタンの中心に対して上下が対称になり、内容が収まる間は、領域の高さは 52pt である
    (上下の余白は、文字の大きさで変化する。13 のときの見出し行は、検索欄 28pt の上下に 12pt ずつ。詳細ページのヘッダの内容の高さは、
    2 行の文字の領域(13 のとき 32pt。比率で連動する)、戻るボタン、前後の会話に切り替えるボタンのうち、最も高いものの高さで、
    13 のときは 32pt の上下に 10pt ずつ)。
    内容が高く、上下の余白が 6pt を下回る場合は、上下の余白を 6pt にして、領域を高くする
    (内容は、上端から 6pt の位置に配置する)。見出し行の下の区切り線と、詳細ページのヘッダの下の区切り線は、この領域の下端に表示する。
  - **スクロール位置**: 文字の大きさを変更したとき、一覧は、表示範囲の先頭にあった行を先頭に表示する。
    会話ペインは、スクロール位置を調整しない。
  - **キー**: ポップオーバーとウィンドウでは、⌘= で 1 大きく(⌘+ も同じ)、⌘− で 1 小さくし、
    ⌘0 で 13 に戻す(上記「キー操作」)。キーは、押した位置ではなく、入力される文字(`=` `+` `-` `0`)で
    判定する。18 での ⌘=、9 での ⌘−、13 での ⌘0 は値を変更しない(キーは処理済みとして扱い、
    フォーカスのあるビューに渡さない)。キーで変更した値も、設定の値として保存する。
  - 値は UserDefaults に保存する。保存済みの値が整数でない場合と、範囲の外の場合は、
    四捨五入して範囲の中の値として扱う(保存済みの値は、次に変更するまで書き換えない)。
    保存済みの値が数値でない場合は、13 として扱う。
- **Setup Check のタブ**(Settings ウィンドウの 2 つ目のタブ。§8.65): 導入の状態の確認。`shiibar-cc doctor --json`(§4.4)の
  結果に、アプリでしか取得できない 2 項目(通知の許可の状態 / ログイン時の起動の登録の状態)を加えて表示する。
  判定のロジックはアプリに複製しない(doctor が正)。開く経路は、Settings ウィンドウのタブだけである
  - **構成**: 見出し付きの枠が 2 つである。**Doctor** = doctor の結果の行、**App** = アプリの 2 項目の行。枠、見出し、行の余白、行の間の線は、
    General のタブと同じである(上記「見た目の規則」)
  - **行**: 左端に結果の記号(✓ / ⚠ / ✗。13pt の太字、幅 16pt の中央。色は、✓ が緑、⚠ が黄、✗ が赤で、確認の結果を示す色である — §3.1 の状態の色とは別である)、
    その右(間隔 8pt)に、結果の要約(13pt。行の幅で折り返す)と、その下に対処のヒント(11pt の二次色。ヒントがある行だけ。折り返す)を表示する。
    右の列(コントロールの列)は無く、要約とヒントは、行の右端まで使用する
  - **Re-run**: 2 つの枠の下(間隔は、枠と枠の間隔と同じ)の右端に、`Re-run` のボタンを表示する。確認の実行中は、ボタンを disabled にして、
    ボタンの中に進行の表示(小さいサイズ)を表示する(最初の実行の間も同じである)
  - **確認を実行する時点**: Setup Check のタブを表示するたびに、自動で実行する(タブを切り替えて戻った場合を含む — 前回の結果を古いまま表示しない)。
    `Re-run` は、その上での手動の再実行である。Settings ウィンドウを開いた時点では、`General` を表示するので、実行しない。
    実行中にタブを切り替えた場合も、実行は中止しない。戻った時点で、前の実行がまだ完了していない場合は、新しく実行せずに、その完了を待つ。
    Setup Check のタブを表示している間に、ウィンドウが key に戻っただけの場合と、Settings… を選択した場合は、実行しない。
    実行中にウィンドウを閉じた場合も、実行は中止せず、その結果は破棄する(次にタブを表示した時点で、新しく実行する)
  - **結果が無い間**(最初の実行が完了する前): 1 つ目の枠(Doctor)の中の、行の位置に、`No results yet.` を二次色で表示する(App の枠は、行が無いので表示しない)。
    2 回目以降の実行中は、前回の結果の行を表示したままにする
- **表示ラベル**: cwd の**末尾 2 要素のみ**を表示(足りなければあるだけ。ホーム配下は
  ホーム相対で数え、`~/` 接頭辞は付けない — ほぼ全てがホーム配下なので情報を運ばない。
  cwd がホームそのものの場合だけ `~`)。
  ラベルの重複はそのまま表示する(並び順が安定していれば足りる。区別の工夫は §8.10)。
  git/worktree の概念は持たない(文字列整形のみ。`repo/branch` に見えるのは worktree のディレクトリ名の偶然)
- **デスクトップ通知**: `UNUserNotificationCenter`。**unreviewed フラグの立ち上がり**(false→true)で発火。
  クリックは delegate で受けて、focus、または一覧での行の選択を実行する(下記「通知のクリック」)。「あなたの番になった」瞬間が通知の起点なので、状態レイヤーと一致する。
  対応ターミナル以外で実行しているセッション(§2 の `process:`)も、同じ規則で通知する
  - 発火は unreviewed の立ち上がりごとに 1 回(再接続 snapshot / reconcile 経由で気づいた unreviewed も含む。切断中の遷移を取りこぼさない)。同じ立ち上がりを二重に通知しないよう発火済みを記録する。
    ただし**アプリ起動後の最初の snapshot は基準線**とし、そこに既に立っている unreviewed には通知しない
    (起動時に過去の未読を再通知しない — 積み残しは未確認の点が示す。起動後の再接続 snapshot は発火対象のまま)。
    **reason が `rekey` の `agent_removed`(§3.6「pid による統合」。`to` が新しい target)は、削除ではなく、target の付け替えとして扱う**:
    発火済みの記録、発火を待っている遅延通知、一覧の行の選択、会話ペインの表示を、`to` の target に引き継ぐ
    (target が付け替わっただけのエントリを、新しい立ち上がりとして通知しない。待っている遅延通知は、`to` の target の最新の状態で再確認し、
    `to` の target の通知として配信する)。
    配信済みの通知は消さず、古い target と `to` の対応を記憶する(下記「通知の掃除」と「通知のクリック」で使用する。アプリの終了で破棄する)。
    対応は、連続して辿る(A → B の後に B → C があれば、A は C に読み替える)。
    **最新の付け替えの `to` は、読み替えの終端にする**: 対応を記憶するときに、`to` を古い target とする対応があれば、先に破棄する
    (A → B の後に B → A があれば、A はそのまま、B は A に読み替える。付け替えが元の target に戻る場合も、対応は循環しない)。
    **エントリが登録または報告された target は、古い target としての対応から外す**: snapshot と `status_changed` に含まれる target を古い target とする対応は、破棄する
    (以前の `process:<pid>` と同じ target で登録された新しいセッションを、ほかのエントリに読み替えないため)。
    辿る回数は、記憶している対応の件数を上限にする(対応は循環しないので、通常は到達しない上限である)。
    古い target と `to` が同じ `rekey` では、何も変更しない(対応を記憶せず、エージェントの一覧も変更しない)
  - **トースト / 音(v1 デフォルト)**: `waiting` の立ち上がり = トースト + 音、interruption level は **time-sensitive**
    (Focus / おやすみモードでも出す。エージェントが止まって待っているのは実際 time-sensitive)。
    完了(idle+unreviewed)の立ち上がり = トースト + **音**(interruption level は active。§8.16)。
    **音は通知に付属させて鳴らす = Focus・おやすみモードに従う**(アプリが直接は鳴らさない。§8.27)。
    音の種類は waiting / 完了それぞれ Settings ウィンドウで選択(`UNNotificationSound(named:)` で
    macOS 標準サウンドを指定。既定はどちらも Glass。§8.26)。
    同一 target で `threadIdentifier` グループ化(同じエージェントの通知が積み上がらない)。
    **Mute sound**(ON = 音を止める = 通知に音を付けない。Settings ウィンドウのスイッチ。UserDefaults 永続)。
    バナーを止めたい場合はアプリ内スイッチではなく **macOS のシステム設定 > 通知**で行う(§8.27)。
    ミュート中も unreviewed フラグ・未確認の点・トレイ表示は動き続ける(見張りは止まらない)。
    イベント別の通知オン/オフの細かい制御は持たない(§8.26 で見送り)
  - **通知の内容**: waiting = タイトル `Waiting for you — <ラベル>`、サブタイトルに `message`(待ちの種別。
    例 "Claude needs your permission")、本文に `task`(どの用件で待たれているか)。
    完了 = タイトル `Done — <ラベル>`、本文に `last_assistant_message`(無ければ `task`)。
    いずれも無いフィールドは行ごと省く(フックが運んでこないもの — 質問文そのもの等 — は出さない。§7-3)
  - 遅延通知: 3 秒後にタイマー発火した時点で**最新状態を再確認**し、まだ unreviewed なら通知する
    (即応した場合だけ通知を出さない仕組み。スリープ跨ぎでも安全)。**対象が前面でも出す**(§8.16 —
    前面かどうかの判定は行わず、`shiibar-cc focused` も呼ばない)
  - 通知の掃除: focus・unreviewed が下りたときに該当 target の配信済み通知を `removeDeliveredNotifications` で消す。
    **そのエントリの以前の target で配信した通知も、同時に消す**(付け替えの対応 — 上記の `rekey` — で、その target に読み替えられる古い target の通知。
    付け替えの前に配信した通知が、確認の後に通知センターに残らないようにする)。
    **`agent_removed` の `reason` が `session_end`(ペイン閉じ)のときは消さない**(まだ見ていない完了通知を、
    タブを閉じただけで撤去しないため)。**`rekey` のときも消さない**(エントリは、新しい target で存続している — 上記)。
    それ以外の reason は掃除してよい(§4.2)
  - **通知のクリック**(§8.66): 通知が持つ target を、付け替えの対応(上記の `rekey`)があれば新しい target に読み替えてから、
    その prefix で分岐する(§4.2「プロトコル契約」)。
    **ジャンプできる target** は、`shiibar-cc focus <target>` を実行する(成功で未確認が下りる)。
    **ジャンプできない target** は、次の順で、一覧のその Running の行を選択する(未確認は、この選択が §9 の時間続いた時点で下りる。その行が既に選択中の場合も、計測を最初から開始する — 上記「未確認を下ろす操作」):
    表示の形の画面(ポップオーバーまたはウィンドウ)を開く → Archive の一覧を表示している場合は、通常の一覧に戻す → Running の区画が閉じている場合は、開く →
    検索文字列がある場合は、消去する → 1 列の詳細ページで、ほかの会話を表示している場合は、一覧のページに戻る(その会話を表示している場合は、詳細ページのままにする)→
    その行を選択する(既に選択中の場合は、選択を解除せず、そのままにする)→ 行の全体が表示範囲に入るようにスクロールする → キーのフォーカスを一覧に移す。
    1 列で、詳細ページを新しく開くことはしない。そのエントリが既に無い場合は、画面を開くだけにする。
    検索文字列を消去した時点で、検索の結果を表示している場合は、Running の区画の絞り込みを、次の一覧の結果を待たずに解除する
    (その行を、消去と同時に表示して選択するため。History の区画は、次の結果が届くまで、検索の結果のままである)。
    **クリックより前に開始した検索の結果は、破棄する**: 消去の時点で、実行中の search を中止し、その結果が後から届いても反映しない
    (消去の前の検索文字列による結果が、選択した行を一覧から外さないようにする)。Running の区画の絞り込みは、クリックの後に開始した search の結果が届いた時点から、通常の規則に戻る。
    **行を選択する時点**: ポップオーバーの形と、開いているウィンドウ(前面に移す場合を含む)では、画面を開いた直後に選択する。
    ウィンドウの形で、閉じているウィンドウを開いた場合は、ウィンドウが key になった時点で選択する(上記「グローバルホットキー」と同じ §9 の時間の中で key になった場合)。
    その時間の中で key にならなかった場合は、その時間が経過した時点で選択する(グローバルホットキーの場合は、フォーカスを移さないままにする。
    通知のクリックは、行を選択する操作なので、key にならなかった場合も実行する)。この後に key になっても、もう一度は実行しない
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
  (黙って握りつぶさない — 本項の大原則)。
- **入力欄の横に表示される AutoFill のメニューを表示しない**(Edit メニューの AutoFill の項目は対象外である — 上記の Edit メニューの記述): 2 つの設定を使用する。アプリのバンドルの `Info.plist` に、`NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac` を true で入れる
  (`scripts/lib/bundle.sh` が生成する)。起動時に、UserDefaults の既定値として、`NSAutoFillHeuristicControllerEnabled` を false で登録する
  (`register(defaults:)` なので、利用者の設定のデータベースには保存しない)。macOS 26 以降は、文字を入力できるすべてのアプリで、Messages または Mail が検出した認証コードの
  AutoFill のメニューが、入力欄のカーソルの横に表示される。`NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac` が true のアプリでは、認証コードの content type を指定した入力欄以外には表示されない(§7-11)。
  `NSAutoFillHeuristicControllerEnabled` は、macOS 26 以降の、入力欄が AutoFill の対象かどうかをシステムが推定する処理を、このアプリのプロセスの中だけで無効にする(§7-11)。
  このアプリには、AutoFill で入力する欄が無い。対象は、検索欄にフォーカスがある間に、アプリが作成していないウィンドウ
  (クラスの名前は `SPRoundedWindow`、ウィンドウレベルはポップアップメニューのレベル)が、検索欄の位置に表示される事象である。
  `Info.plist` のキーだけでは、このウィンドウは表示される。`NSAutoFillHeuristicControllerEnabled` を false にしたビルドでは、表示されない(§7-11)
- **daemon のライフサイクル管理**: アプリ起動時に socket へ接続し、応答があれば**既存 daemon にアタッチ**する
  (アプリのクラッシュ等で残った orphan daemon もここで回収される。daemon 側の二重起動防止は §4.2 の
  起動シーケンスが担う)。応答がなければ同梱の `shiibar-ccd` を spawn し、バックオフ再接続で繋ぐ。
  アプリ終了(Quit)時は `shutdown` を送って daemon も止める。
  **バージョンが異なる daemon には、アタッチしない**: 応答があった daemon に `info` を送り、`version` が、アプリのバンドルのバージョン
  (`CFBundleShortVersionString`。末尾の `-dev` は除いて比較する。アプリと daemon は、同じワークスペースのバージョンでビルドする —
  §8.28)と異なるときは、その daemon に `shutdown` を送り、daemon が停止した後に、同梱の `shiibar-ccd` を spawn する
  (アプリを更新した後に、更新の前の daemon が残っている場合に、ワイヤの形式が異なる組み合わせで動作しないようにするため。§8.66)。
  比較は、アタッチのたびに(起動時と、再接続の時点で)実行し、daemon の `version` からも末尾の `-dev` を除く。
  「停止した」は、socket のファイルが無くなった、または socket への接続が拒否される状態である(それ以外の接続のエラーは、停止していないと判定する —
  起動中かもしれない daemon と並べて、同梱の daemon を spawn しないため)。`shutdown` の送信から §9 の時間まで、0.1 秒の間隔で確認し、
  その時間の中で停止しなかったときは、spawn せず、切断の状態のままにして、切断の警告行を表示する(下記の再接続が続く)。
  **停止しなかった入れ替えは、保留にする**: その後のアタッチのたびに(このアプリが spawn した daemon が実行中である場合を除く)、daemon が停止しているとき
  (上記の「停止した」の条件)は、同梱の `shiibar-ccd` を spawn して、アタッチする(保留は、この spawn で終了する。spawn は 1 回だけである)。
  停止していないときは、`info` も `shutdown` も送らずに、応答した daemon にアタッチし、保留を継続する(その daemon が後で停止した時点のアタッチで、spawn する)。
  停止を確認できない間は、spawn しない。`shutdown` を送るのは、アプリの 1 回の起動につき 1 回までである。
  **この入れ替えは、アプリの 1 回の起動につき 1 回だけ実行し、このアプリが spawn した daemon には実行しない**
  (「このアプリが spawn した daemon」は、このアプリが spawn したプロセスが実行中である間の、応答した daemon である。停止しなかった入れ替えも、1 回に数える)
  (同梱の daemon のバージョンが、バンドルのバージョンと異なる場合に、終了と起動を繰り返さないため。バージョンが異なる 2 つのアプリが、
  同じ state dir で同時に起動している場合も、それぞれ 1 回で止まる)。この条件で入れ替えないときは、バージョンが異なっても、アタッチする。
  **アプリのバンドルのバージョンを取得できない場合、または同梱の `shiibar-ccd` が無い場合(バンドルにしないで実行したアプリ)は、
  比較せずにアタッチする**(手動で起動した daemon との併用 — `docs/DEVELOPMENT.md`)。
  `version` が同じときは、そのままアタッチする。`info` が失敗したときは、アタッチする(応答する daemon を、情報の取得の失敗だけで終了させない)
- **ログイン時起動**: `SMAppService.mainApp` を使う。**初回起動時のみ自動登録**する
  (実施済みかだけを UserDefaults に記録し、以後は自動登録しない — OFF にした選択を次回起動で
  上書きしないため)。以降の ON/OFF は Settings ウィンドウの「Start at Login」スイッチで行い、
  チェック表示は毎回 SMAppService の status を読む(システム設定側で変えられてもずれない。
  自前フラグを状態の正にしない)。install スクリプトはアプリを一度起動するだけで、
  Login Items API を直接は呼ばない
- **reconcile の実行**: アプリは `shiibar-cc reconcile` を **(1) 起動時 / daemon 再接続時、(2) 定期
  (`NSBackgroundActivityScheduler`、間隔 約 60 秒・tolerance 30 秒。§9。システムスリープ中は OS が
  スケジュールを止め、復帰後に自然に再開する — 自前の画面状態検知はしない)、(3) Refresh(見出し行の
  Refresh のボタン / ⌘R。§4.6)** で呼ぶ(§3.5/§8.22)。これで hooks の取りこぼしによる
  status ドリフト(「working のまま固まる」等)と daemon 不在中の穴(幽霊・見逃した waiting)を自己修復する。
  起動時・再接続時・定期の実行では、メッセージ行に一時表示を表示しない(一時表示は Refresh だけが表示する。
  §4.6)。hooks 主軸のリアルタイム性は保ったまま backstop になる。
  どの契機でも、TCC エラー(exit 3)は警告行(上記)に表示する
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
  読ませ、**左上 1/4 エリアの中央に大きな ✻(素の U+273B)**、**右肩に青い点**(明色ハロー付き。色は §9 の固定の値で、既定のアクセントカラーに近い青である。アイコンの画像は、利用者のアクセントカラーの設定に
  追従できないので、固定の値にする —「未確認を知らせる見張り」の一言。状態記号の縦積みは持たない)。32px 以下は ✻ のみ(中央)の簡略版
  (点は小サイズで潰れるため付けない)。install スクリプトが生成スクリプトから `.icns` を
  作って同梱する(`CFBundleIconFile`)。ジオメトリの正は生成スクリプト(リポジトリ内)
- **同梱**: `shiibar-ccd` / `shiibar-cc` は .app の `Contents/Helpers/` に同梱する。アプリは同梱バイナリを
  絶対パスで呼ぶ(PATH 非依存)。install スクリプトが `~/.local/bin/shiibar-cc` → 同梱バイナリへの
  シンボリックリンクを張り、hooks や手動 CLI は PATH 経由で同じ実体を使う(**アプリを入れれば全部入る**)

### 4.6 Conversations(会話の一覧・検索・閲覧・再開)

会話の履歴をフォルダ横断で**一覧し**(browse)、**検索し**(search)、**全文を表示し**(read)、新しい
ターミナルウィンドウで**再開**(Resume)または**分岐**(Branch)する機能。消費者は 2 つ —
**アプリとスクリプト(CLI)** — で、どちらも同じ CLI コマンドを使用する。
ポップオーバーとウィンドウ(§4.5)では、Starred と Recent の区画と会話ペインがこの機能の表示である。
**daemon・プロトコル・hooks・状態モデルには変更を加えない**(§8.34)。状態モデルとの接点は
2 つ — (1) Running の行(daemon の一覧)と session_id が一致する会話を Starred と Recent から除く
(2) Resume / Branch のターミナル選択と Jump が、アプリが購読済みのエージェント一覧を参照する
(下記「Resume と Branch」。§8.47)。
会話の識別子は Claude Code の session ID をそのまま使用する。見た目の正は `docs/window-design.html`。
**会話ペイン**は、1 つの会話を表示する領域(ヘッダ・検索バー行(1 列だけ)・メッセージ面・下部パネル)の名前である。
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
  **対話でない方法で起動した会話の transcript は、会話として扱わない**(§8.67): transcript の行のうち、`entrypoint` の項目を持つ行のすべてで、
  値が `sdk-cli` であるファイルは、索引に会話として登録しない(`search` の結果に含まれず、`show` は exit 2 になる。人の発話が無い transcript と同じ扱いで、
  ファイルの `(パス, mtime, サイズ)` を記録して、追いつきで読み直さない)。`entrypoint` を持つ行が 1 つも無いファイルと、`sdk-cli` 以外の値を持つ行が
  1 つでもあるファイル(`claude -p` で開始した会話を、対話で再開した場合を含む)は、会話として扱う。
  **人の発話が 1 つも無い transcript は、会話として扱わない**(§8.64): 発話列(下記)に人の発話が無いファイルは、索引に会話として登録しない。
  `search` の結果に含まれず、`show` は、索引に無い session-id と同じ結果(exit 2 — §4.4)を返す。
  Claude Code を起動して、発話を送らずに終了したセッション(スラッシュコマンドだけを実行したセッション、起動時の指定の誤りで終了したセッションなど)が該当する。
  後から人の発話が追加されたファイルは、次の追いつき(下記)で、会話として登録する。
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
  rewind を機構なしで吸収できる)。読み直した結果、人の発話が 1 つも無いファイルと、対話でない方法で起動した会話のファイル(上記「索引の内容」)は、会話として登録せず(登録済みの会話は索引から消す)、
  そのファイルの `(パス, mtime, サイズ)` だけを記録する(変化するまで読み直さない。変化したときは、ほかのファイルと同じく読み直して、
  人の発話があれば会話として登録する)。消えたファイルは索引からも消す (2) pid ファイルから live/past
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

#### History(Starred と Recent の区画)と会話ペイン(アプリ)

- **Recent の区画**(§4.5 の一覧の、History の見出しの下の 2 つ目): `conversations search` の結果から、**Running の行と
  session_id が一致する会話と、スター付きの会話(下記「Starred の区画」)と、Archive した会話(下記「Archive」)を除いたもの**を表示する
  (同じ会話を複数の区画に表示しない。
  除外は表示のたびに適用するので、Running に行が現れた時点で、対応する History の行は消える)。
  **並び**: 新しい順(`updated_at` の降順 = search が返す順)。
  **表示する行は、この並びの先頭から §9 の上限までである**。上限を超えた会話があるときは、
  Recent の行の枠の下に、表示していない会話の数を 1 行で表示する — クエリが空の結果を表示している間は
  `N more — search to narrow down`、有効なクエリの結果を表示している間は `N more — refine your search`(この行は選択できない。
  下記「空状態」の文言も、同じ条件で決まる)。
  **上限を超えた会話がある間は、見出しの行数を `first 100` の形式にする**(`Recent` の後に
  `first` と上限の数。表示している行が、並びの先頭からの一部であることを示す — §8.56。
  History の見出しが Recent の見出しを兼ねている間は、History の見出しが `History first 100` になる — §4.5「一覧は 3 つの区画」)。
  上限以下の間の見出しは、名前と行数である(§4.5)。
  ↑ / ↓ の移動、詳細ページの位置は、表示している行だけを対象にする。
  上限は表示だけに適用する(search の結果そのものは制限しない — スターの整理と、Running の行の
  タイトルの取得は、結果の全体を使用する。Archive した会話の整理も同じである)。上限は、Archive した会話を除いた後の並びに適用する。
  行は 3 行 — **1 行目 = フォルダラベル**(ラベルは §4.5 と同じ末尾 2 要素規則。経過時間は、記号と時間の列に表示する — §4.5)/
  **2 行目 = タイトル**(太字。null はフォルダラベルで代替する)/
  **3 行目 = その会話で最後に自分が送った発話**(search の `last_prompt`。
  null なら空行にして、行の高さをそろえる)。**3 行目は検索中も最後の発話のままである**
  (ヒットした箇所の抜粋に差し替えない)。記号と時間の列の上は、スターと三点リーダーである(下記「スター」「Archive」)。下部パネルの主ボタンは Resume である(§4.5「実行のボタン」)。
  - **live の会話が Starred または Recent に残る場合**(daemon に、その `session_id` のエントリが無い会話 —
    reconcile がそのセッションを登録するまでの間、ターミナルの走査が不完全な回が続いている間の、hook の報告がまだ無いセッション、
    ターミナルを持たないセッション(§4.1)、`session_id` が空のエントリのセッション。
    対応ターミナル以外で実行しているセッションは、daemon が追跡するので、通常は Running の行になる — §8.66): 1 行目(ラベル)の末尾に `· running` の淡いテキスト印を
    表示し、下部パネルの主ボタンは **disabled の Jump**(理由の表示は
    `Running in a terminal Shiibar CC can't drive` — README と同じ語彙)にする。Branch は押せる
  - **cwd の無い会話**は Resume と Branch を disabled にする(resume は cwd 必須 — §4.4。
    disabled の間もツールチップは `Resume` / `Branch` のままで、下部パネルに理由は表示しない)
  - **空状態**: 通常の一覧で、どの区画にも行が無いときだけ(閉じている区画の行も、行として数える。Archive した会話は数えない)、一覧の位置に 1 行を表示する —
    クエリが空の結果を表示している間は `No conversations`、有効なクエリの結果を表示している間は `No matching conversations`。
    索引の全構築中(下記「ポップオーバーまたはウィンドウを開いたとき」)と、起動後に最初の search の結果を
    受け取るまでの間は、この 1 行を表示しない
- **Starred の区画**(§4.5 の一覧の、History の見出しの下の 1 つ目。§8.60): `conversations search` の結果のうち、スター付きの会話を表示する
  (Running の行と session_id が一致する会話を除く。Archive した会話は、スターを持たない — 下記「Archive」)。
  **並びは、利用者が決めた順序である**(下記「スター」の順序付きの一覧の順。検索中も同じ)。
  表示する行の数に上限は無い(§9 の上限は、Recent だけに適用する)。
  行の内容と動作は、Recent の行と同じである(3 行の内容、`· running` の印、下部パネルの主ボタンが Resume であること、
  cwd の無い会話の扱い)。上記「Recent の区画」の行についての規則は、並びと上限を除いて、Starred の行にも適用する
- **スター**(§8.49 / §8.59 / §8.60): 通常の一覧の History の行の、記号と時間の列の上の、三点リーダーの左に表示する(大きさは §9。クリックに反応する範囲は、記号の枠である。§4.5「一覧は 3 つの区画」)。
  Archive の一覧の行には、スターを表示しない(下記「Archive の一覧」)。
  Recent の行にホバーすると輪郭だけの星を表示し、クリックするとスターが付く(ツールチップは `Star`)。
  Starred の行は、黄色の塗りの星を、ホバーしていなくても表示する。クリックすると、スターを解除する(ツールチップは `Unstar`)。
  スターのクリックでは行を選択せず、ダブルクリックの動作を実行せず、行のドラッグ(§4.5)も開始しない。
  スターの変更は直後に表示へ反映する。**スターを付けた会話は、Starred の末尾に追加する**。
  スターを解除した会話は、Recent の新しい順の位置に表示する(上限を超える位置の会話は、表示しない)。
  スターは、行のドラッグでも変更できる(§4.5「行のドラッグ」)。
  **スターはアプリの表示設定**であり、**session_id の順序付きの一覧**を UserDefaults に保存する
  (一覧の順が Starred の並びである)。CLI・索引・
  Claude Code 側には書き込まない(索引 DB は自動で再構築されるキャッシュなので保存先にしない)。
  **スター付きの会話が Running にある間は、Running にだけ表示する**(星は表示しない。Running の行の記号は、状態記号だけである)。
  スターと、順序付きの一覧の中の位置は保持し、会話が終了すると、Starred の、一覧の順の位置に表示する。
  Branch で作成した会話はスターを引き継がない(別の session_id になる)。
  **スターは会話の削除を防がない**: Claude Code が保存期間を過ぎた transcript を削除すると(§7-6)、
  その会話は一覧から消える。クエリが空の一覧を取得した時点で、一覧に無い session_id のスターを破棄する
  (残りのスターの順序は変更しない)。
  **順序の無い保存値**: UserDefaults に、順序付きの一覧が無く(値が想定の形でない場合を含む)、順序付きの一覧を
  保存しないバージョンのアプリが保存した、順序の無いスターの集合がある場合は、その集合をスターとして使用し、新しい順に表示する。
  クエリが空の一覧を取得した時点で、新しい順に並べた結果を、順序付きの一覧として保存する。
  その前にスターを変更したとき(星のクリック、行のドラッグ)は、その時点で、取得済みの search の結果にある会話を
  新しい順に、結果に無い会話をその後に session_id の順に並べて、順序付きの一覧にしてから、変更を適用して保存する。
  順序付きの一覧を保存した後は、順序の無い集合の値を使用しない(値は削除しない)。
  順序付きの一覧に同じ session_id が複数ある場合は、最初の 1 つだけを使用する
- **Archive**(§8.63): 会話を、通常の一覧(Starred と Recent)から外して、Archive の一覧(下記)に移す操作である。
  会話と transcript は削除しない。
  **三点リーダーのボタン**: 通常の一覧の History の行の、記号と時間の列の上の右端に、常に表示する(横に並ぶ 3 つの点。二次色。大きさは §9。
  クリックに反応する範囲は、記号の枠である。ツールチップは `More`、アクセシビリティの名前は `More actions`)。
  Running の行には表示しない。クリックすると、ボタンの下に、右端をボタンの右端にそろえて、項目が 1 つのメニューを表示する。項目は **`Archive`** である
  (Archive の一覧の行では **`Unarchive`** — 下記)。メニューを開いている間は、三点リーダーの枠に、淡い灰色の地(角丸 5pt)を表示する。
  三点リーダーのクリックでは、スターと同じく、行を選択せず、ダブルクリックの動作を実行せず、行のドラッグ(§4.5)も開始しない
  (key でないウィンドウの三点リーダーをクリックしたときは、ウィンドウを key にして、同じクリックでメニューを表示する)。
  メニューの項目を選択しないで閉じたときは、何も変更しない。Archive のキー操作と、行の右クリックのメニューは無い。
  - **`Archive` を選択すると**、その会話を、すぐに通常の一覧から外す(search を再実行しない)。スター付きの会話は、スターを解除する
    (スターの順序付きの一覧から外す。Unarchive しても、スターは戻らない)。選択中の行を Archive したときは、
    選択なしにする(§4.5「行の選択」の、一覧から無くなった行の扱い)。確認の表示と、取り消しの表示は無い
    (2 回の操作で実行するので、1 回のクリックでは Archive されない。戻す操作は、Archive の一覧の `Unarchive` である)
  - **Archive できない行**: Running の行(三点リーダーが無い)と、**live の会話が Starred または Recent に残っている行**
    (`· running` の印がある行 — 上記「Recent の区画」。メニューの `Archive` を disabled にする)。実行中のセッションを
    一覧から外さないためである
  - **Archive の自動の解除**: **live の会話は、Archive の一覧に含めない**。Archive した会話が live である場合は、その会話の Archive を解除する。
    live の判定は 2 つで、どちらかに該当すれば live である: session_id が同じ Running の行がある / search の結果が、その会話を live(`live: true`)と報告している
    (daemon にエントリが無い実行中の会話は、Running の行にならないので、search の結果で判定する — 上記「Recent の区画」)。
    Running の行は、検索の条件で一覧に表示していない間も、この判定の対象にする(live であることは、セッションの状態で、表示の状態ではない)。
    メニューを開いた後に live になった会話で `Archive` を選択した場合は、何も変更しない(Archive せず、スターも外さない)。
    判定は、エージェントの一覧、search の結果、Archive の一覧のどれかが変化するたびに実行する(アプリの起動後の最初の一覧、
    Running の行が後から session_id を持った場合、Running の行が現れる前に開いたメニューで `Archive` を選択した場合を含む)。
    アプリからの Resume の後と、ターミナルで `claude --resume` を実行した場合の、どちらも該当する。再開した会話は、使用中の会話であり、
    終了した後は Recent に表示する
  - **保存**: Archive は、スターと同じく、アプリの表示設定である。**Archive した会話の session_id の、順序付きの一覧**を
    UserDefaults に保存する(一覧の順は、Archive した時刻の新しい順である。新しく Archive した会話を、先頭に追加する)。
    ポップオーバーとウィンドウで共通で、アプリを再起動しても保持する。CLI・索引・Claude Code 側には書き込まない。
    保存済みの値が想定の形でない場合は、Archive した会話が無いものとして扱う。同じ session_id が複数ある場合は、最初の 1 つだけを使用する。
    Branch で作成した会話は、Archive を引き継がない(別の session_id になる)。
    **Archive は会話の削除を防がない**: クエリが空の一覧を取得した時点で、一覧に無い session_id を、Archive の一覧から破棄する(スターと同じ規則)
- **Archive の一覧**(§8.63): Archive した会話だけを表示する、一覧のもう 1 つの表示である。⌄ メニューの **Archived** で表示する
  (§4.5「⌄ メニュー」。Archive した会話が 1 つも無い間は、項目が disabled である。この判定には、保存している Archive の一覧を使用し、
  search の結果を待たない)。
  - **表示する内容**: Running、Starred、Recent の区画と、その見出しを表示しない。一覧の先頭に、**帯の見出し `‹ Archived`** を表示し
    (帯の形は §4.5「一覧は 3 つの区画」の帯と同じ。左から、左向きの山形 `‹`、名前 `Archived`、行数。右端の山形は無い)、
    その下に、Archive した会話の行を、1 つの枠の中に、**Archive した時刻の新しい順**に表示する(保存している一覧の順)。
    表示するのは、`conversations search` の結果にある会話だけである。表示する行は、この並びの先頭から §9 の上限(Recent と同じ値)までで、
    上限を超えた会話があるときは、行の枠の下の `N more` の行と、見出しの `first 100` の形式を、Recent と同じ規則で表示する(上記「Recent の区画」)。
    最初の search の結果を受け取る前(アプリの起動の直後、索引の全構築中)は、帯の見出しに行数を表示せず、帯の下には何も表示しない。
    結果を受け取った時点で、行数と行を表示する
  - **行**: 3 行の文字、経過時間、cwd の無い会話の扱いは、Recent の行と同じである(live の会話は Archive を自動で解除するので、
    `· running` の印がある行は無い — 上記「Archive」)。記号と時間の列の上は、
    三点リーダーだけである(スターを表示しない)。三点リーダーのメニューの項目は **`Unarchive`** で、選択すると、その会話を Archive の一覧から外す
    (会話は、通常の一覧の Recent の、新しい順の位置に表示する)。
    行の選択、クリック、ダブルクリック、↑ / ↓、詳細ページ(View、→、⌥↑ / ⌥↓)、会話ペイン、下部パネルのボタン(Resume / Branch)は、
    通常の一覧の History の行と同じである。行はドラッグできない(ドラッグできない理由の表示も無い)。
    **選択中の行が、`Unarchive` または Archive の自動の解除で Archive の一覧から外れたときは、選択なしにする**(その結果、通常の一覧に戻る場合を含む。
    1 列の詳細ページでは、一覧のページに戻る)
  - **通常の一覧に戻る操作**: 帯の見出し `‹ Archived` のクリック(帯の全体がクリックの範囲である。キーのフォーカスを変更しない。
    帯のクリックから始まる連続したクリックは、区画の見出しと同じく、2 回目以降は何もしない — §4.5「区画の開閉」。戻った後にポインタの下に来た見出しまたは行を、操作しないためである)、Esc(§4.5「キー操作」。
    1 回目の Esc は戻る操作だけを実行し、ポップオーバーを閉じない)、⌄ メニューの **Archived**(チェックマークが付いている項目)の選択。
    **最後の 1 つを Unarchive したとき**(Archive の自動の解除と、一覧に無い session_id の破棄で、Archive した会話が無くなったときを含む)も、通常の一覧に戻る
  - **表示は記憶しない**: ポップオーバーまたはウィンドウを閉じると、通常の一覧に戻る(`Open in window` と `Open in popover` で表示の形を切り替えたときと、
    ポップオーバーの中の Resume / Branch / Jump の成功でポップオーバーを閉じたときを含む)。アプリの起動後は、通常の一覧である。
    Archive の一覧を表示したままにすると、次に開いたときに Running の行が表示されず、waiting のセッションに気付けないためである。
    ウィンドウで Archive の一覧を表示したままにしている間は、通常の一覧に戻るまで、Running の行は表示しない(waiting の状態は、トレイアイコンの表示で分かる)
  - **スクロール位置**: Archive の一覧は、表示するたびに、最上部から表示する。通常の一覧に戻ったときは、切り替える前の、通常の一覧のスクロール位置に戻す
  - **検索**: 検索欄のプレースホルダは `Search archived` である。クエリが有効な間は、search の結果のうち、Archive した会話だけを、
    Archive した時刻の新しい順に表示する。見出しの行数は、表示している行の数である。該当する会話が無いときは、帯の見出しの下に
    `No matching conversations` を表示する。**通常の一覧と Archive の一覧を切り替えても、検索欄の文字は変更しない**(同じ文字列で、もう一方を検索できる)
  - **切り替えたときの選択**: 選択中の行が、切り替えた後の一覧に無いときは、選択なしにする(§4.5「行の選択」。1 列の詳細ページでは、一覧のページに戻る)
  - **Archive の一覧を表示している間のほかの動作**: Refresh(ボタン、⌘R)、History を再取得する契機、メッセージ行、警告行、キーの案内は、通常の一覧と同じである。
    Running の行は表示しないが、トレイアイコンの表示と通知は変化しない。グローバルホットキーとトレイアイコンのクリックで閉じたときは、上記のとおり通常の一覧に戻る
- **検索の適用範囲**: クエリが有効な間、**Running の行は、session_id が search の結果に含まれる行だけを
  表示する**(session_id が空の行は表示しない)。Starred と Recent は search の結果(上記の振り分けの後)である。
  **通常の一覧の検索は、Archive した会話を表示しない**(Archive した会話は、Archive の一覧の検索で表示する — 上記「Archive の一覧」)。
  **History の見出しの下に、Starred の行(利用者が決めた順序)と、Recent の行(新しい順。§9 の上限まで)を、
  この順に、1 つの枠の中に続けて表示する**(§8.60)。Starred と Recent の見出しは表示しない(スター付きの行は、星で区別できる。
  スターを変更した行は、同じ枠の中で、変更の後の位置に移動する)。`N more` の行は、この枠の下に表示する。
  一覧にはヒットの抜粋も件数も表示しない(会話ペインがヒット位置を表示する。§8.49)。
  見出しの行数は、検索中は表示している行の数になる。History の見出しの行数は、Starred の行と Recent の行の合計である
  (Recent の行が上限を超えている間は、`first` と、この合計の数を表示する)。
  検索中は、見出しに山形と Running の印を表示せず、見出しを開閉できない(§4.5「区画の開閉」)。行はドラッグできない(§4.5「行のドラッグ」)
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
  (2 文字以上)が 1 つも無い間は search を発行せず** browse 一覧のまま(プレースホルダは
  `Search (2+ characters)`。Archive の一覧を表示している間は `Search archived` — 上記「Archive の一覧」)。
  **Refresh** は、見出し行の Refresh のボタン(§4.5「見出し行」)と ⌘R(§4.5「キー操作」)で実行する。どちらも同じ操作である(§8.54 / §8.62)。
  **Refresh は、表示している一覧の全体を最新にする操作である**: 同じクエリでの search の再実行(Starred と Recent の区画)と、
  `shiibar-cc reconcile`(Running の区画。§4.5「reconcile の実行」)の両方を開始し、両方の終了を待つ。
  実行中にもう一度 Refresh を実行しても、何もしない(実行中は、見出し行の Refresh のボタンを押せない。§4.5「見出し行」)。
  Refresh の search が終了する前に、ほかの契機(打鍵など)で search を開始した場合は、Refresh の search を中止し、
  後から開始した search の結果を、Refresh の search の結果として扱う。Refresh の search が終了した後に開始した
  search の結果は、Refresh の結果に影響しない。
  **実行には、必ず表示の反応がある**: 実行中は、見出し行の Refresh のアイコンが回転し、メッセージ行(§4.5「固定フッター」)に `Refreshing…` を表示し
  (索引の進捗またはエラーを表示している間も、`Refreshing…` を優先して表示する。下記「メッセージ行」)、
  search と reconcile の両方が終了した時点で、次の表の結果を表示する
  (一時表示の時間は §9。件数は表示しない。`Refreshing…` を表示する時間に、最低の長さは無い)。

  | search | reconcile | 終了後の表示 |
  |---|---|---|
  | 成功 | 成功 | `✓ Refresh done`(一時表示) |
  | 成功 | TCC エラー(exit 3) | 一時表示なし。警告行に TCC エラーを表示する(§4.5) |
  | 成功 | それ以外の失敗 | `Refresh failed`(一時表示) |
  | エラー終了 | (どの結果でも) | `Search failed`(メッセージ行のエラー。下記)。reconcile が TCC エラーのときは、警告行にも表示する |

  **search がエラー終了したときは前回の結果を維持**して、メッセージ行にエラーを表示する
  (打鍵途中の一過性の失敗で一覧を消さない。Refresh 以外の契機の search も同じである)
- **History を再取得する契機**(search の再実行。§8.49): ポップオーバーを開いたとき /
  ウィンドウを開いたとき / **ウィンドウが key になったとき**(他のアプリから戻った時点で最新にする)/
  打鍵 / Refresh(見出し行の Refresh のボタン / ⌘R)/ アプリからの Resume・Branch の成功直後 / **Running の行が消えたとき**(`agent_removed`。
  終了した会話を History に表示するため。直後の再取得では、終了の途中のプロセスがまだ生存していて
  会話が live と判定される場合があるので、§9 の時間の後にもう 1 回再取得する)。
  search の結果は、これ以外の契機では更新しない
  (Running の行と一致する会話の除外と、スターによる区画の振り分けと並びは、search を再実行せずに直後に反映する)。
  FSEvents による監視は持たない。複数の契機が重なったときは 1 回にまとめてよい。
  **表示中の会話が結果に残っている間、search の結果の更新そのものは、会話ペインの表示を変更しない**(下記「表示の状態規則」。
  会話ペインの内容を更新する契機は、下記「会話ペインの再読み込み」が定める)
- **会話ペインの表示**: 会話ペインが表示する会話が決まると(1 列で詳細ページを開いたとき、
  2 列で行を選択したとき、1 列の詳細ページで ⌥↑ / ⌥↓ またはヘッダの前後のボタンで会話を切り替えたとき)、`conversations show` で
  **全文を 1 回で取得**し、古い順に表示する(下端 = 最新)。スクロールは自由。
  Running の行の会話では、先に `conversations index` を実行し、その終了の後に(exit code に関係なく)show を実行する
  (show は追いつかないので、先に索引を最新にする。この index の扱いは、下記「会話ペインの再読み込み」の契機 1 の index と同じである)。
  History の行と、Archive の一覧の行の会話では、show だけを実行する。
  `session_id` が空の行では、show を実行しない(§4.5「行のクリック」)。
  show が exit 2(索引に無い — 直前に消えた等)または exit 1 のときは、メッセージ面に
  1 行のエラーを表示する(一覧は維持)。**Running の行の会話で show が exit 2 のとき**は、エラーではなく、
  メッセージ面の中央に `No conversation to show` の 1 行を表示する(発話をまだ送っていないセッションは、索引に無い — 上記「索引の内容」。
  `session_id` が空の行と同じ表示である)。この表示は、その行を選択し直したときと、下記「会話ペインの再読み込み」の契機で、
  show を再度実行して更新する(その時点の transcript に人の発話があれば、会話を表示する)。
  **会話ペインのヘッダ**は 1 行目 = **フォルダラベル**(一覧の行のラベルと同じ末尾 2 要素 — §4.5)+ 経過時間、
  2 行目 = タイトルである(一覧の行と同じラベルとタイトルを、同じ順序で表示する — §8.59)。
  1 行目は `demo/menubar-app · 3h ago` の形式である(一覧の行の経過時間は `3h` の形式)。`running` の印は、ヘッダには表示しない。
  **1 列の詳細ページのヘッダ**は、2 行の文字の左に**戻るボタン**(一覧のページに戻る。← と同じ。
  ツールチップ `Back`。大きさとアイコンは、見出し行のボタンと同じで、文字の大きさに連動する — §4.5「文字の大きさ」)、右に**一覧の中での位置**(`2 / 4`。表示している行の中で何番目か /
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
  **本文に 1 件以上あるときだけ**、カウンタと ‹ › を表示して(1 列では会話の上部の検索バー行、2 列では見出し行 — 下記)、
  全語を同色でハイライト(現在位置のみ濃く)、初期位置は**どれかの語の最新の出現**。0 件なら表示せず下端から。
  **検索バー行は macOS 標準の文書内検索の文法**(§8.38): カウンタは `N of M`、移動は
  **‹ › のセグメンテッドコントロール**(ツールチップは `Previous match` / `Next match`)。次(`›`・⌘G)= 新しい方へ /
  前(`‹`・⇧⌘G)= 古い方へ。**端まで行ったら反対側へ折り返す**(⌘G の慣習)。
  **`N of M` の N は、会話の先頭(最も古い出現)を 1 として数える**。初期位置は最新の出現なので、
  開いた直後のカウンタは `M of M` になる。
  **1 列の詳細ページの検索バー行は、左端に検索文字列を文として表示する** — `Matches for “tag”`
  (`Matches for` は淡い色、引用符で囲んだ検索文字列は通常の色。長い検索文字列は途中を省略する)。
  詳細ページには検索欄が無く、何を検索しているかを確認できないためである。表示だけで、ここでは変更できない。
  入力欄と区別できるように、背景・枠・虫眼鏡のアイコンを付けない。この行では、カウンタと ‹ › を右端に配置する。
  **2 列では、検索バー行を表示しない。カウンタと ‹ › は、見出し行の検索欄と Refresh のボタンの間に配置する**(§4.5「見出し行」。§8.62)。
  コントロールは**内容サイズ**にする(幅いっぱいに伸ばさない — §8.38)。ヒットが無い間は、見出し行にカウンタと ‹ › を表示しない。
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
- **会話ペインの再読み込み**(§8.65): 会話ペインは、表示している会話を、次の契機で再度取得して、表示を更新する。
  実行中の会話を表示したままで、送った発話と Claude の返答を読むためである。
  - **契機 1(セッションの状態の変化)**: Running の行の会話を表示している間に、その行のセッションの `status`(§3.1)が、
    アプリが直前に受け取った値から変化したとき(working / waiting / idle の間の、すべての変化が対象である)。
    状態が変化した時点で再読み込みし、その時点の transcript の内容を表示する。
    `unreviewed` だけの変化と、`status` 以外の項目だけの変化では、再読み込みしない。応答の途中の文字は表示しない
    (更新するのは、状態が変化した時点と、下記の「契機 1 の後の再読み込み」だけである)。ポップオーバーとウィンドウのどちらも表示していない間の変化では、再読み込みしない
  - **契機 1 の後の再読み込み**: 契機 1 の再読み込みが完了してから §9 の時間の後に、契機 1 と同じ手順で、もう 1 回再読み込みする
    (状態の変化の通知の後に transcript に書き込まれた内容を表示するため)。契機 1 の再読み込みの実行中に次の契機が発生した場合と、
    契機 1 が実行中の再読み込みの後の再実行にまとめられた場合は、その再実行の完了の後に実行する。この時間の間に、別の再読み込みが開始したとき、
    表示する会話が切り替わったとき、ポップオーバーとウィンドウのどちらも表示しなくなったときは、実行しない。
    この再読み込みの後には、もう 1 回の再読み込みを実行しない
  - **契機 2(表示の開始)**: Running の行の会話を表示している状態で、ポップオーバーを開いたとき、ウィンドウを開いたとき、
    ウィンドウが key になったとき(表示していない間の変化を反映する)
  - **契機 3(Refresh)**: Refresh を実行したとき(見出し行のボタン / ⌘R)。表示している会話が、History の行、
    Archive の一覧の行の会話でも、再読み込みする
  - **手順(契機 1)**: `conversations index`(追いつきだけを実行する — 上記「索引の更新」)を実行し、その終了の後に
    `conversations show` を実行する(show は追いつかないので、先に索引を最新にする。search は再実行しないので、一覧は変化しない)。
    index の exit code に関係なく、show を実行する。この index は、ポップオーバーまたはウィンドウを開いたときの index
    (下記「ポップオーバーまたはウィンドウを開いたとき」)とは別のプロセスとして実行し、互いに中止しない。
    この index の進捗、全構築の状態、エラー終了は、表示せず、一覧の状態(History の表示、検索欄、メッセージ行)を変更しない
  - **手順(契機 2 と契機 3)**: その契機で実行する search(上記「History を再取得する契機」)が追いつきを含むので、
    search の結果を受け取った後に、show だけを実行する。契機の後に最初に受け取った search の結果(成功または失敗)を、
    その契機の search の結果として扱う(その契機の search が、後の契機の search に置き換えられた場合を含む)。
    契機 2 で、index がエラー終了して search を実行しないとき(下記「ポップオーバーまたはウィンドウを開いたとき」)は、
    index の終了の後に show を実行する
  - **手順(共通)**: `session_id` が空の行では、実行しない。再読み込みの実行中(index または search の終了を待っている間を含む)に
    次の契機が発生したときは、実行中の再読み込みの完了の後に、1 回だけ再度実行する。この再実行は、契機の種類に関係なく、
    契機 1 の手順(index、show の順)で実行する。会話の最初の読み込み(上記「会話ペインの表示」)の実行中に発生した契機は、
    最初の読み込みの完了の後に実行する。再読み込みの実行中に、表示する会話が切り替わったときは、その結果を破棄する。
    再読み込みの間、表示中の内容を維持する(読み込み中の表示にしない)
  - **結果の反映**: show が成功したときは、次のとおりに表示を更新する。発言の比較は、`seq`、`role`、`text`(§4.4)で実行し、
    3 つがすべて一致する発言を、同じ発言とする。
    `No conversation to show` またはエラーの 1 行を表示していたときは、上記「会話ペインの表示」と同じく、会話を最初から表示する。
    発言の列が表示中と同じとき(発言の数が同じで、すべての発言が同じ)は、終端マーカーの経過時間だけを更新する。
    表示中の発言がすべて同じで、末尾に発言が追加されているときは、追加された発言だけを末尾に追加する
    (表示中の発言の選択範囲、展開の状態、コピーの反応を維持する)。
    表示中の発言が変化しているとき(発言の数が減った場合を含む)は、全体を描画し直す(選択範囲と展開の状態は破棄する)。
    show が失敗したとき(exit 1、exit 2、出力を解釈できない)は、表示中の内容(会話、`No conversation to show`、エラーの 1 行)を維持し、
    エラーを新しく表示しない
  - **スクロール**: 表示を更新する直前に、終端マーカー(下記「下端(最新)の手がかり」)の一部が表示範囲にあったときは、
    更新の後に、下端までスクロールする(末尾を読んでいる間は、新しい末尾を表示する)。それ以外のときは、スクロール位置を変更しない
    (途中を読んでいる間は、読んでいる位置を維持する。全体を描画し直したときは、表示範囲の先頭にあった発言を、同じ位置に表示する。
    その発言が無くなったときは、下端までスクロールする)。発言の列が表示中と同じとき(終端マーカーの経過時間だけを更新するとき)は、終端マーカーの位置に関係なく、スクロール位置を変更しない
  - **ヒット**: 有効な検索文字列がある間は、更新した発言の列でヒットを再計算して、カウンタとハイライトを更新する。
    現在位置は、再読み込みの前と同じ出現のままにする(発言が追加されただけのときは、`N of M` の N は変化せず、M だけが変化する)。
    再読み込みの前にヒットが無かったとき、または全体を描画し直したときは、最新の出現を現在位置にする。
    どの場合も、ヒットの位置へはスクロールしない(スクロールは、上記の規則だけで決まる)
  - **終端マーカーの経過時間**: show の `updated_at`(§4.4)と、再読み込みの時点の時刻から求める
- **表示の状態規則**: 選択中の会話が結果に残っている間、search の結果の更新そのものは、会話ペインの表示を変更しない
  (search の結果を受け取っただけでは、全文を再取得せず、スクロール位置も変更しない。選択は session_id で保持する。表示を更新するのは、上記「会話ペインの再読み込み」の契機だけである)。
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
  見ている」が読める。経過時間は、会話を取得した時点の値で、
  その後は、会話ペインの再読み込み(上記)のときだけ更新する。**上に続きがある間だけ**ヘッダの下に薄いスクロールシャドウを出す
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
  選択範囲には影響しない。押した後は、一定時間(§9)、アイコンをチェックマークに替え、同時に、アイコンの左に
  小さい表示 **`Copied`** を表示する(アイコンの形の変化だけでは、コピーが実行されたことに気付きにくいため。§8.65)。
  `Copied` は、枠線と地を持つ小さい角丸の表示で(寸法は window-design.html の CSS 値が正)、ラベルの行の高さと、
  ほかの要素の位置を変更しない。同じ発言のボタンを、表示の間にもう一度押したときは、その時点から一定時間、表示を続ける。
  コピーのボタンと `Copied` の表示は、選択・コピーの対象に含めない
- **下部パネル**(1 列の一覧のページの下端と、会話ペインの下端。disabled のボタンの理由を表示している間を除いて、常に同じ高さ): 選択中の行を対象にする
  Jump / Resume / Branch を、ラベル付きのボタンで表示する(§4.5「実行のボタン」)。
  右端が主ボタン(**Resume** または **Jump**)、その左が **Branch**(副ボタン)。
  主ボタンは選択中の会話の状態で決まる(§8.48 / §8.49):
  - Running の行にある会話 → **Jump**(ジャンプできないセッションの行では **disabled の Jump** — §4.5「実行のボタン」)
  - History の会話 → **Resume**
  - History に残る live の会話 → **disabled の Jump**(理由の表示は
    `Running in a terminal Shiibar CC can't drive`)

  **disabled のボタンに理由がある間は、理由を、ボタンの行のすぐ上の行に、右寄せの文字で表示する**(§8.66)。ポインタをボタンに重ねる操作をしなくても、
  押せない理由が画面で分かる。文字の大きさはキーの案内と同じで、色は淡色である。理由があるのは、disabled の Jump(上記の文言)と、
  選択したターミナルを使用できないときの Resume と Branch(下記「Resume と Branch」の文言)である。同じ文言を、
  そのボタンのツールチップにも設定する。主ボタンと Branch の理由が同じ場合は 1 行だけ表示し、異なる場合は、主ボタンの理由、Branch の理由の順に
  2 行で表示する。理由が無い disabled(cwd の無い会話、再取得が完了するまでの間)と、ボタンを表示していない間は、表示しない。
  理由を表示している間は、パネルが理由の行の分だけ高くなり、一覧またはメッセージ面の表示範囲が、その分だけ狭くなる。ボタンの行(キーの案内とボタン)の配置と、
  パネルの下端からのボタンの位置は、理由の有無で変わらない。理由の 1 行は、パネルの幅の全体を使用する(幅が不足する場合は、末尾を省略する)。

  **1 列の一覧のページでは、Branch の左に View ボタンを表示する**(副ボタン。§8.59)。押すと、選択中の行の
  詳細ページを開く(一覧にフォーカスがある間の → と同じ)。View は、ほかのボタンと同じ条件で表示し、
  disabled にはならない。詳細ページと、2 列の右の列には、View を表示しない(会話を表示しているため)。

  **1 列では、パネルの左側にキーの案内を配置する**。一覧のページの案内は §4.5「固定フッター」のとおりで、
  詳細ページの案内は `⌥↑↓ Prev / Next` / `← Back` である(見た目は同じ)。
  一覧のページで行を選択していない間は、ボタンを表示せず、キーの案内だけを表示する
  (パネルの高さは変更しない)。一覧のページと詳細ページで、Branch と主ボタンの位置と大きさは同じである。
  **検索欄にフォーカスがある間は、行を選択していても、ボタンを表示しない**(1 列でも 2 列でも同じ。
  パネルの高さは変更しない。その間の Enter は一覧にフォーカスを移す操作で、⌘Enter は何もしないため — §8.55)。
  1 列では、キーの案内(`↩ List`)だけを表示する。2 列の右の列では、パネルに何も表示しない。
  一覧にフォーカスを移す(行のクリック、行のドラッグの開始、検索欄での Enter)と、ボタンを表示する。
  2 列の右の列では、左側には何も配置しない(キーの案内は左の列のフッターにある)。
  **ボタンの中に、ラベルに続けてショートカットを表示する**: 主ボタンは `Resume ↩` または `Jump ↩`、
  Branch は `Branch ⌘↩`、View は `View →` である(ショートカットの記号は、ラベルより淡い色で表示する。disabled の間も表示する)。
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
  **どのターミナルで開くかは、Settings の `Terminal` の値で決める**(§4.5「Settings ウィンドウ」。§8.66): 値を `--terminal` に渡す
  (iTerm2 = `iterm2`、Terminal = `apple-terminal`、Ghostty = `ghostty`)。実行中のセッションのターミナルは、開く先に影響しない
  (対応ターミナル以外で実行しているセッションの Branch も、選択したターミナルで開く)。
  **選択したターミナルを使用できないとき**(§4.5「Settings ウィンドウ」の Terminal)は、Resume と Branch を disabled にして、
  下部パネルに理由を表示する(上記) — `iTerm2 is not installed — choose a terminal in Settings` /
  `Ghostty is not installed — choose a terminal in Settings` / `Ghostty 1.4.0 or later is required — choose a terminal in Settings`
  (cwd の無い会話の disabled には、理由の表示が無い。両方に該当する場合は、ターミナルの理由を表示する)。
  **一覧の表示からクリックまでの時間差で、他の場所で resume された会話への二重 resume は防がない**
  (意図的な割り切り。§8.34)
- **Jump**: 選択中の会話に対応する Running の行の target へ `shiibar-cc focus <target>` を実行する。
  成功時の seen 送信・TCC(exit 3)の扱い・該当なし(exit 2)でエラーを表示しない点は、
  §4.5「実行のボタン」のとおりである。成功すると、ポップオーバーは閉じ、ウィンドウは閉じない。
  ジャンプできるかどうかは、target の prefix で判定する(§4.2。ジャンプできない target では、主ボタンが disabled で、focus を実行しない)。
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
  **全構築中(`start` の `full_build` が true — §4.4)は検索欄を無効にして進捗だけを表示する**(Refresh の実行中は、下記「メッセージ行」の優先順位に従って `Refreshing…` を表示する)
  (構築中の部分結果は表示しない — §8.34)。
  index がエラー終了したら、メッセージ行にエラーを表示する(次の契機で回復)。前回の History があるときは
  表示したままにし、無いときは History を表示しない。
  Running の区画は index を待たずに表示する(daemon の一覧であり、索引に依存しない)。
  行の選択は §4.5「行の選択」の規則に従う。1 列では、利用者が View ボタンを押すか、一覧にフォーカスがある間に → を押すまで
  詳細ページを開かない
- **メッセージ行**(固定フッター。§4.5): **表示の優先順位**は、Refresh の実行中の `Refreshing…` > 索引の進捗 > エラー >
  Refresh の結果の一時表示(`✓ Refresh done` / `Refresh failed`。表示時間は §9)である。
  Refresh の実行中は、索引の進捗またはエラーを表示する状態でも、`Refreshing…` を表示する(§8.61)。
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
│   ├── dev-demo.sh         # README のスクリーンショット用の、実際の会話と設定から分離した撮影用の環境を用意する
│   ├── generate-app-icon.swift  # アプリアイコンの唯一の原本(bundle.sh が実行して .icns を生成・同梱)
│   ├── lib/                # スクリプト共有部(bundle.sh = .app 組み立て+署名の単一ソース、署名 ID 管理、アプリ/daemon 停止、撮影用のサンプルのデータ)
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
│   ├── ci.yml              # main への push とプルリクエストで cargo test / clippy / swift build / swift test / cask style + cargo-deny(§10)
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
   ウィンドウを閉じた場合の SessionEnd の時点では、`claude` のプロセスは制御端末を持たない(下記 12。hook は、`target` を持たない report を送る — §4.1)。
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
   **spawn 型セッションの report を、親のエントリにそのまま適用した場合の影響(実測)**: 子の SessionStart / UserPromptSubmit / Stop / SessionEnd が
   親と同じ target を上書きする。子の Stop で親の target が idle + unreviewed になり(親が作業中でも
   「あなたの番」フラグが立つ偽アラート)、子の SessionEnd(reason:"other")で `agent_removed` =
   タブのエントリが一旦メニューバーから消える。親の次の hook で working として再登録される(task 欄は
   次の UserPromptSubmit まで空)。短命な子ならチラつく程度だが、親が idle / waiting で止まっている間に
   子が終了するとタブのエントリが消えたまま残り得る。
   **この影響は、§3.6「入れ子のセッション」の規則で防ぐ**: 子の report は、親と同じ pid を持ち、`session_id` が親と異なるので、daemon が無視する
   (pid が親と同じになることは、Bash ツールが起動した `claude -p` で実測 — 下記 9。コーディネータが起動する種類の子では、実測していない)。
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
     `TERM_PROGRAM` は VS Code が `vscode` で上書きする(§7-1 で実測済み)ので、report の target は `apple-terminal:` にならず(`process:` になる — §4.1)、
     仮に `apple-terminal:` になっても VS Code の pty は Terminal.app のタブ一覧に無いので focus は「該当なし」・
     reconcile は `process:` で送る(完全な走査の回に、エントリは `process:` に付け替わる — §3.6「pid による統合」の「reconcile」)。iTerm2 の UUID 相続と違い、相続される値(`TERM_SESSION_ID`)を
     target に使っていないため、誤誘導の材料が残らない
   - **`id` もタブも読み取れないウィンドウ**(2026-11-21、macOS 27.2.1。`osascript` の実行で確認): Terminal.app は、ターミナルのウィンドウをすべて閉じた後も
     起動している間、ターミナルのウィンドウではないウィンドウのオブジェクトを保持する場合がある。その状態では、`count of windows` は 1、
     そのウィンドウの `exists` は true で、`id of w` はエラー(-1728)、`tabs of w` と `count of tabs of w` はエラー(-10000 または -1728)になる。
     `tabs of w` を `try` の外で読み取るスクリプトは、この状態でスクリプトの全体がエラーになる。
     §4.3 の走査と `focused` のスクリプトを、この状態の Terminal.app で実行し、走査が失敗 0 件で完了すること、`focused` が「なし」を返すことを確認した。
     この規則を加えた focus のスクリプトでの、実際のタブへの移動は、未検証である(実機スモークで確認する)
8. **Ghostty の実挙動** — 実機で検証済み(2026-11-21、Ghostty 1.4.0 / macOS 27.2.1 / Claude Code 2.1.330)。未検証の点は、末尾に列挙する:
   - **アプリのバンドル**(インストールされているアプリのバンドルの `Info.plist` を読んで確認): バンドル ID は `com.mitchellh.ghostty`、
     `CFBundleShortVersionString` は `1.4.0`
   - **AppleScript の辞書**(アプリのバンドルの `Ghostty.sdef` を読んで確認): クラス `terminal` に `id` / `name` / `working directory` /
     `pid` / `tty`。`tab` に `selected` / `focused terminal`、`window` に `selected tab`、`application` に `front window` / `version` / `frontmost`。
     コマンドは `focus`(terminal を対象にして、そのウィンドウを前面にする)/ `activate window` / `select tab` / `new window` / `new tab`
     (surface configuration のレコードを渡す: `initial working directory` / `command` / `initial input` / `environment variables` など)/
     `input text` / `send key`
   - **環境変数**(Ghostty のタブのシェルと、そこで起動した `claude` の hook で確認): `TERM_PROGRAM=ghostty`、
     `TERM_PROGRAM_VERSION=1.4.0`、`TERM=xterm-ghostty`、`GHOSTTY_SURFACE_ID`(16 進の値で、AppleScript の `id` とは一致しない)。`ITERM_SESSION_ID` は無い
   - **hook の祖先 walk と tty**(Ghostty のタブで対話の `claude` を起動し、hook で親連鎖を記録して確認。SessionStart と SessionEnd):
     親連鎖は `hook の sh(??) → claude(ttysNNN) → シェル → login → ghostty` で、最初に制御端末を持つ祖先は `claude` 本体である(Terminal.app と同じ — 上記 7)。
     その pid と tty は、AppleScript の `pid of terminal` と `tty of terminal`、`claude agents --json` の一覧の pid と一致した
   - **列挙の結果**(2 つのウィンドウ、2 つのタブ、1 つの分割を作成して、全 `terminal` の `id` / `tty` / `pid` を取得して確認):
     `id` は UUID の形式の文字列。`tty` は `/dev/ttysNNN` の形式で、ウィンドウ、タブ、分割のそれぞれの端末が、別の `terminal` と `tty` を返した。
     `pid` は、`claude` を実行している端末では `claude` のプロセスの pid、シェルだけの端末ではシェルの pid である。ウィンドウの `id` は `tab-group-…` の形式である
   - **列挙中に端末を閉じた場合**: `terminal` を 1 つずつ取り出す列挙(`repeat with s in terminals`)は、列挙の途中で端末が閉じられると、
     エラー -1719(正しくないインデックス)になる(3 回の試行で 3 回)。`tty of every terminal` の形の、1 回の照会での取得は動作する。
     → 列挙は 1 回の照会で取得し、エラーは不完全な走査として扱う(§4.3)
   - **`focus`**(別のウィンドウ、同じウィンドウの別のタブ、同じタブの別の分割の端末を対象にして確認): `every terminal whose tty is "<tty パス>"` で端末を特定できる。
     `focus` だけで、前面のウィンドウの選択中のタブの `focused terminal` が、対象の端末に変化した(`activate window` と `select tab` の併用は不要)。
     tty が一致しない場合は、該当が 0 件になり、何も動かない。前面の端末は `tty of focused terminal of selected tab of front window` で取得できる
   - **新しいタブとウィンドウでのコマンドの実行**: surface configuration の `initial input` に、コマンドと末尾の改行を指定すると、`new tab` でも `new window` でも、
     対話シェルでコマンドが実行された。`claude` は、シェルの rc を通った PATH で解決された。`input text` は貼り付けの扱いで、改行を含めても実行されない
     (実行には `send key "enter"` が必要)。空白、`'`、`"` を含むフォルダへの `cd '…'` は、シェルの単一引用符のエスケープ(`'\''`)と、
     AppleScript の文字列のエスケープの組み合わせで成功した
   - **ghostty モジュールが生成するスクリプトの形での確認**(§4.3 のスクリプトを `osascript` で実行して確認): バージョンの照会
     (`application "Ghostty"` の is-running の確認の中での `version` の取得)は、`1.4.0` を返した。一括の走査(`tty of every terminal`)は、全端末の tty を返した。
     `activate` の後の `new window with configuration`(`initial input` に、コマンドと `linefeed`)は、新しいウィンドウの対話シェルでコマンドを実行した。
     `focused` のスクリプトは、Ghostty が前面でない状態で「なし」を返した
   - **1.4.0 未満の Ghostty**(Ghostty のリポジトリのタグ `v1.3.0` と `v1.3.1` のソースを読んで確認。実物では実行していない): `macos/Ghostty.sdef` の
     `terminal` には `tty` と `pid` が無い(§9 の最小のバージョンを 1.4.0 とする根拠)。`application` の `version` はある。
     `TERM_PROGRAM_VERSION` は、`v1.3.1` でも設定される(`src/termio/Exec.zig`)
   - **リリースではないビルドのバージョンの形式**(タグ `v1.4.0` の `src/build/Config.zig` を読んで確認): `X.Y.Z-<ブランチ名>+<短いハッシュ>`、
     または `X.Y.Z-dev+0000000`。→ 比較は、最初の `-` または `+` より前の部分で行う(§4.1)
   - **AppleScript を無効にする設定**(タグ `v1.4.0` の `src/config/Config.zig` を読んで確認): 設定の名前は `macos-applescript`、既定の値は true である
   - **帰結**: 中(hook の環境)と外(AppleScript)の両方から導出できる鍵は tty である。target は `ghostty:<tty パス>` とし、
     hook では祖先 walk で tty を取り(§4.1)、reconcile と focus では `tty of terminal` と突き合わせる(§4.3)
   - **未検証**(実機スモークで確認する。結果によって §4.3 を変更する項目は、その旨を記載する):
     - 別のアプリが前面にある状態からの `focus` で、Ghostty が前面のアプリになること(ならない場合は、`focus` の前に `activate` を実行する — §4.3)。
       別の Space にある端末への移動
     - Ghostty が前面のアプリである状態で、`focused` のスクリプトが、前面の端末の tty を返すこと
     - Ghostty が起動していないときに、`application "Ghostty" is running` の照会が Ghostty を起動しないこと、
       `new window` が Ghostty を起動して、`initial input` のコマンドが実行されること
     - Ghostty がインストールされていない Mac で、バージョンの照会のスクリプトが「未起動」を返すこと(下記 10 は、インストールされていない別の名前での確認である)
     - オートメーション(TCC)の許可が無いときのエラーが、ほかのターミナルと同じ判定(exit 3 — §4.4)で扱えること
     - **`macos-applescript` が false のとき**: `version` の照会と `tty of every terminal` の照会が返すエラー(番号と文言)。
       §4.3 の規則(TCC 以外のエラーは、不完全な走査)では、この設定の Ghostty が起動している間、reconcile の prune が止まる。
       エラーを判別できる場合は、1.4.0 未満と同じ扱い(空の結果を完全な走査として返す。セッションは `process:` になる)にする。
       doctor の検査に加えるかどうかも、この結果で決める
     - Ghostty から起動した別のアプリ(エディタなど)の中のターミナルに、`TERM_PROGRAM=ghostty` と `TERM_PROGRAM_VERSION` が相続されるかどうか
       (相続される場合、その中のセッションは `ghostty:<tty>` で報告されるが、その tty は Ghostty の terminal に無いので、
       完全な走査の reconcile が `process:<pid>` で送り、エントリは `process:` に付け替わる — §3.6「pid による統合」の「reconcile」。
       付け替えまでの間は、Jump が「該当なし」になる。付け替えの後は、hook の report が target を戻さない)
     - AppleScript の `version` が、リリースではないビルドで返す値の形式(`TERM_PROGRAM_VERSION` と同じ形式であることを前提にしている)
9. **祖先 walk の pid、入れ子のセッション、対応ターミナル以外のセッションの追跡** — 一部を実機で検証済み(2026-11-21、Claude Code 2.1.330 /
   iTerm2 3.7.6 / Ghostty 1.4.0 / macOS 27.2.1)。未検証の点は、末尾に列挙する:
   - **祖先 walk の pid**(hook で親連鎖を記録して確認): Ghostty の対話の `claude` では、hook の `sh` は制御端末を持たず、その親の `claude` が持つ(上記 8)。
     iTerm2 では、`claude` の子のシェル(Bash ツールのシェル)が制御端末を持たず、親の `claude` が持つことを確認した。Terminal.app は上記 7。
     Ghostty と iTerm2 のどちらでも、walk で取る pid(制御端末を持つ `claude` の pid)は、`claude agents --json` の一覧の、同じセッションの pid と一致した
     (hook が登録する `process:<pid>` と、reconcile が送る `process:<pid>` が、同じ target になる前提である — §3.5)
   - **walk の段数**: `shiibar-cc report` → hook の `sh` → `claude` で、2〜3 段である。入れ子の `claude -p` の hook から親の `claude` までは、5 段程度で、§9 の上限に収まる
   - **Bash ツールが起動した `claude -p`**(iTerm2 で実行中のセッションの Bash ツールから実行し、子の hook で親連鎖を記録して確認):
     親連鎖は `hook の sh(??) → 子の claude(??) → Bash ツールのシェル(??) → 親の claude(ttysNNN)` である。子の `claude` は制御端末を持たないので、
     walk は親の `claude` に到達し、子の SessionStart(`source` は `startup`)/ UserPromptSubmit / Stop / SessionEnd(`reason` は `other`)は、
     すべて、親と同じ pid と tty を取る。`ITERM_SESSION_ID` と `TERM_PROGRAM` も相続する。`session_id` は、親と異なる。
     hook の内容の項目は、対話のセッションのものと同じで、入れ子であることを示す項目は無い。
     → hook は、`entrypoint` の値で、子の report を送らない(§4.1・§7-13)。送られた場合も、daemon が、pid と `session_id` の組で判別して無視する(§3.6「入れ子のセッション」)。
     子のプロセスは tty を持たず、`entrypoint` でも除外するので、`claude agents` の一覧に含まれる場合も、reconcile は送らない(§3.5)
   - **切り離して起動した `claude -p`**(親が pid 1 のプロセス): 制御端末を持つ祖先が無いので、report は drop される(§4.1)。
     `claude agents --json` の一覧には、`kind` が `interactive` で含まれる(tty を持たず、`entrypoint` でも除外するので、reconcile は送らない)
   - **ターミナルのシェルから実行した `claude -p`**(Ghostty のタブで確認): hook は実行され、`claude -p` のプロセス自身が、そのタブの制御端末を持つ。
     実行している間は、`claude agents --json` の一覧に、`kind` が `interactive` で含まれる。**一覧の `kind` では、`claude -p` と対話のセッションを判別できない**。
     hook と reconcile は、`entrypoint` の値で、このセッションを対象外にする(§4.1・§3.5・§7-13)
   - **Stop が 2 回送信される場合**: 上の `claude -p` の実行では、1 回の応答で Stop が 2 回送信された(2 回目は、項目 `stop_hook_active` が true)。
     2 回とも §3.4 の同じ行を適用する(結果は同じである)
   - **hook の実行時間**(2026-11-21。リリースビルドの `shiibar-cc report PostToolUse` を、条件ごとに 60 回実行して計測。開始から終了までの時間。
     どの条件でも祖先 walk を実行し、対応ターミナル以外は、`process:` の report を socket に書き込む):

     | 条件 | 中央値 | 最大 |
     | --- | --- | --- |
     | iTerm2、daemon あり | 3.7 ms | 5.5 ms |
     | iTerm2、daemon なし | 3.6 ms | 4.3 ms |
     | Terminal.app、daemon あり | 3.6 ms | 4.6 ms |
     | Terminal.app、daemon なし | 3.7 ms | 4.5 ms |
     | 対応ターミナル以外(`process:` として送信)、daemon あり | 3.7 ms | 6.0 ms |

     どの条件も 100 ms より小さく、§4.1 のタイムアウト(1 秒)に対して、十分に短い。
     ビルドの直後の、バイナリの最初の 1 回の実行は 233 ms である(表には含めない)
   - hook の内容には、pid と tty は含まれない(`fixtures/` の各ファイルの内容。項目の一覧は `fixtures/README.md`)
   - **SessionStart の `source` と SessionEnd の `reason` の値**(Claude Code の公式の文書の hooks のページを読んで確認、2026-11-21):
     `source` は `startup` / `resume`(`--resume`、`--continue`、セッションの中での `/resume`)/ `clear` / `compact` / `fork`
     (`--fork-session`、セッションの中での分岐、バックグラウンドへの移動など)。`reason` は `clear` / `resume`(セッションの中での `/resume` による切り替え)/
     `logout` / `prompt_input_exit` / `other`
   - **既知の制限**(どれも、§3.6 の規則のとおりの動作である。回復の方法を併記する):
     - **iTerm2 のタブの中で、独自の端末を持つプロセスから起動した `claude`**: 独自の端末を持ち、`TERM_PROGRAM` と `ITERM_SESSION_ID` を相続するプロセス
       (`screen` など)から起動した `claude` の report は、タブの target(`iterm2:<UUID>`)を持つ。report は、target が一致するエントリを、pid が一致するエントリより
       先に解決するので(§3.6「pid による統合」)、タブのエントリに適用される(タブのセッションの状態と `session_id` を上書きし、SessionEnd では、タブのエントリを削除する)。
       次の完全な reconcile が、タブのエントリを `claude agents` の内容で上書きする。その後の report で、もう一度発生する
     - **制御端末を持つ、`claude` 以外の祖先から、切り離して起動された `claude`**(ターミナルから起動したサーバーが、tty を持たない `claude` を起動する場合など):
       祖先 walk は、その祖先に到達するので、report は、祖先の pid の `process:<pid>` で登録される。`claude` のプロセス自身は tty を持たないので、reconcile は送らず、
       完全な reconcile のたびに、エントリを prune する。次の report で、もう一度登録される。この形で `claude` を起動する実物は、確認していない
     - **daemon の起動の後、最初の reconcile より前に受信した report**: 復元したエントリは pid が不明なので(§3.6)、復元したエントリと種類が異なる target の report
       (復元したエントリが `ghostty:<tty>` で、report が `process:<pid>` の場合など)は、新しいエントリとして登録され、同じセッションのエントリが 2 件になる。
       次の完全な reconcile が、片方に pid を設定し、もう片方を prune する。prune された側で立っていた未確認は、失われる
     - **完全な reconcile が実行されない状態が続く間**(起動中のターミナルの Automation の許可が無い場合など): prune が実行されないので、終了したセッションのエントリが、
       pid を保持したまま残る(stale の削除まで — §3.6 の「削除経路」)。同じ pid を再利用した新しいセッションの report は、そのエントリに pid で解決され、`session_id` が異なるので、
       入れ子のセッションの report として無視される場合がある。完全な reconcile が実行されると、回復する
     - **ウィンドウを閉じてから、行が消えるまでの時間**: ターミナルのウィンドウを閉じて終了したセッションの行は、SessionEnd の hook が実行されるまで(約 3.5〜5.5 秒 — 下記 12)残る。
       その間に、走査が完全な reconcile があると、行は `process:<pid>` の行(ジャンプできない行)になり、SessionEnd で消える。
       hook が実行されない終了(プロセスの強制終了、クラッシュなど)では、次の完全な reconcile の prune で消える
     - **同じ `session_id` を、2 つのプロセスが resume している場合の、片方のウィンドウを閉じる操作**: `target` を持たない SessionEnd は、
       `session_id` が同じエントリをすべて削除するので(§3.6)、実行を続けている側のエントリも削除される。実行を続けている側は、次の reconcile で、
       新しいエントリとして登録される(§3.5)
     - **Resume のコマンドの中の制御文字**: Resume のコマンドは、ターミナルに入力として渡す(§4.3)。`session_id` または cwd に制御文字が含まれる場合、
       シェルの単一引用符では、ターミナルの入力としての働き(キーの入力として解釈される文字)を無効にできない。回復の方法は無い
       (`session_id` は UUID で、cwd は実在するフォルダである)
   - **未検証**:
     - 対応ターミナル以外のターミナル(エディタのターミナルなど)で、hook の `sh` が制御端末を持たず、walk が `claude` に到達すること、
       その pid が `claude agents --json` の一覧の pid と一致すること、一覧が、そのセッションを pid と一緒に含むこと
     - Terminal.app での、対話の hook の親連鎖の、Claude Code 2.1.330 での再確認(上記 7 は 2026-07-16 の値)
     - `TERM_PROGRAM` が無い環境で、ターミナルから起動したセッションが、`process:` で報告されること
     - **ターミナルを持たないセッション**(エディタの拡張機能、常駐プロセスが起動する実行など): hook が実行されるかどうか、
       祖先 walk が制御端末を持つプロセスに到達しないこと(report を drop する前提である — §4.1)
     - **セッションの中での切り替え**: `/resume` と、セッションの中での分岐で、SessionEnd と SessionStart が送信される順序、それぞれの `session_id`、
       `source` と `reason` の実際の値(`/clear` は上記 3 で実測済み。§3.6「入れ子のセッション」の 3 が適用する `source` の根拠である)
     - **`claude -p` 以外の子のセッション**(コーディネータが起動する種類 — 上記 3、バックグラウンドに移動したセッションなど): 子の hook の祖先 walk が到達するプロセス、
       取る pid と tty、`claude agents` の一覧に含まれるかどうか。子のプロセスが自分の制御端末を持つ場合は、その tty または pid の target になり、
       親とは別のエントリになる(iTerm2 では、相続した `ITERM_SESSION_ID` から親と同じ target を導出し、pid が親と異なるので、§3.6「入れ子のセッション」の 2 で、親のエントリを上書きする)
     - 対応ターミナル以外で、daemon が無い場合の、hook の実行時間(対応ターミナル以外のセッションでも、hook のたびに daemon の socket への接続を試みる)
10. **インストールされていないアプリを対象にした AppleScript** — 実機で検証済み(2026-11-21、macOS 27.2.1。インストールされていないアプリの名前と
    バンドル ID を指定したスクリプトを、`osascript` で実行して確認)。未検証の点は、末尾に列挙する:
    - **バンドル ID での指定**: `application id "<インストールされていないアプリのバンドル ID>"` を含むスクリプトは、実行の前にエラー(-1728)になる。
      その参照が、`is running` の条件の中、または `try` の中にあっても同じである
    - **名前での指定**: `application "<インストールされていないアプリの名前>" is running` は、false を返す(エラーにならない)。
      is-running の確認の中で、`tell` で `version` だけを取得するスクリプトも、エラーにならず、起動していない側の分岐を実行する
    - **固有の用語**: アプリの固有の用語(そのアプリの辞書が定義するクラス、プロパティ、コマンド)を `tell` の中で使用するスクリプトは、
      そのアプリがインストールされていない場合、名前で指定しても、実行の前にエラー(-2741)になる。同じスクリプトの中の is-running の確認は、実行されない。
      iterm2 モジュールの走査と同じ形のスクリプト(`tabs of w`、`session si of t`、`tty of thisSession`)と、ghostty モジュールの走査と focus と同じ形の
      スクリプトで確認した
    - **帰結**: 固有の用語を使用するスクリプトは、固有の用語を使用しない照会で起動中であることを確認した後に送り、アプリは名前で指定する(§4.3「共通規則」)
    - **未検証**: iTerm2 がインストールされていない Mac と、Ghostty がインストールされていない Mac での、実物の名前での確認
      (`shiibar-cc reconcile` が完全な走査を送ること、doctor がそのターミナルを `[info]` の「未起動」として表示すること)
11. **認証コードの AutoFill のメニュー** — Apple の公式の文書で確認(2026-11-21、Information Property List の
    `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac` のページ)。未検証の点は、末尾に列挙する:
    - macOS 26 以降は、文字を入力できるすべてのアプリで、Messages または Mail が受信した認証コードの AutoFill が有効である。
      コードを検出してから 3 分以内で、入力欄にフォーカスがある場合に、AutoFill のメニューが、入力のカーソルの横に表示される
    - `Info.plist` の `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac`(Boolean。既定は NO。macOS 26.0 以降)を true にしたアプリでは、
      認証コードの content type(AppKit では、入力欄の `contentType` に `oneTimeCode`)を指定した入力欄以外に、このメニューが表示されない
    - **アプリの中で記録した事象**(2026-11-21、macOS 27.2.1。アプリのプロセスが表示するウィンドウの、クラスの名前、大きさ、ウィンドウレベルの記録で確認。記録の処理は、§8.68 で削除した): 検索欄にフォーカスが移った時点で、
      アプリが作成していないウィンドウが、検索欄の入力の位置に表示される。クラスの名前は `SPRoundedWindow`、ウィンドウレベルは 101
      (ポップアップメニューのレベル)で、内容は表示されない
    - **`Info.plist` のキーだけでは、上の事象は止まらない**(2026-11-21、macOS 27.2.1。キーを true にしたバンドルで、同じウィンドウが表示された。
      表示と同じ時点で、システムのログに、`com.apple.SafariPlatformSupport.Helper` への接続の開始が記録される)
    - **`NSAutoFillHeuristicControllerEnabled`**(UserDefaults。false で、AutoFill の対象の推定を無効にする): Apple の公式の文書には記載が無い。
      macOS 26 で、AutoFill の推定が原因の問題に対して、ほかのアプリケーションが採用している設定である(2026-11-21 に、Web の検索の結果で採用の事実を確認。
      それぞれの変更の内容は未確認)
    - **`NSAutoFillHeuristicControllerEnabled` を false にしたビルドでは、上の事象は発生しない**(2026-11-21 から 2026-11-23 まで、macOS 27.2.1。
      アプリの外のプロセスから、`CGWindowListCopyWindowInfo` で、アプリのプロセスが画面に表示しているウィンドウの一覧(ウィンドウレベル、位置、大きさ)を、
      1 秒より短い間隔で取得して確認。false にする前のビルドでは、この方法で、該当するウィンドウを複数回記録した。
      false にしたビルドでは、約 43 時間の記録で、該当するウィンドウは 0 件である)
    - **未検証**: 上の事象のウィンドウが、どの種類の AutoFill のメニューであるか
12. **ターミナルのウィンドウを閉じたときの SessionEnd** — 実機で検証済み(2026-11-21。Terminal.app 488.9 / Ghostty 1.4.0 / iTerm2 3.7.6 / macOS 27.2.1。
    対話の `claude` を起動したウィンドウを、AppleScript の `close window` で閉じ、SessionEnd の hook の中で、時刻と、`ps -o pid,ppid,tty` による
    祖先の連鎖を記録して確認)。未検証の点は、末尾に列挙する:
    - **hook は実行される**: 3 つのターミナルのどれでも、SessionEnd の hook は、ウィンドウを閉じてから約 3.5〜5.5 秒後に実行され、最後まで実行される。
      payload の `reason` は `other` である
    - **その時点で、制御端末が無い**: hook の親の `claude` のプロセスは、制御端末を持たない(`ps` の tty は `??`)。その祖先(親が pid 1 になっている)も持たない。
      環境変数(`TERM_PROGRAM`、`ITERM_SESSION_ID` など)は残っている。`claude` の pid は、それ以前の report の祖先 walk で取った pid と同じである
    - **閉じてから hook までの間**: 約 3.5〜5.5 秒の間、`claude` のプロセスは、tty を持ったまま動作している。この間に reconcile が実行されると、
      そのセッションは、ターミナルの走査には無く、`ps` では tty を持つので、エントリは `process:<pid>` に付け替わる(§3.5)。付け替えは `session_id` を引き継ぐ
    - **帰結**: 制御端末を持つ祖先が無い SessionEnd は、`target` を持たない report として送り、daemon は `session_id` でエントリを決める
      (§4.1、§3.6「`target` を持たない SessionEnd」)
    - **`target` を持たない SessionEnd による削除**(2026-11-21。同じ版のターミナル。一時的な state dir で起動した daemon に、すべての hook のイベントの
      report を送る設定で、対話の `claude` を起動し、ウィンドウを閉じてから、daemon の一覧からエントリが無くなるまでの時間を、0.5 秒の間隔で計測して確認):
      エントリが無くなるまでの時間は、Terminal.app が 3.6 秒、Ghostty(`close window`)が 5.4 秒、iTerm2 が 5.4 秒である。daemon は、どの場合も、
      `target` を持たない SessionEnd で、`session_id` が一致するエントリを削除した。SessionEnd の hook の時点の `claude` のプロセスは、どの場合も、
      制御端末を持たず、親が pid 1 である
    - **iTerm2 の、タブを閉じる操作**(同じ方法。2 つのタブを持つウィンドウの、片方のタブを閉じた): ウィンドウを閉じた場合と同じで、
      SessionEnd の時点で制御端末が無く、エントリは 5.4 秒で無くなる
    - **閉じた直後の reconcile との組み合わせ**(iTerm2。ウィンドウを閉じた約 1 秒後に、`shiibar-cc reconcile` を実行した): エントリは、
      閉じてから 2.5 秒の時点で `process:<pid>` に付け替わり、5.6 秒の時点で、`target` を持たない SessionEnd によって無くなる
    - **Ghostty の、端末を対象にした `close`**: AppleScript の `close`(`terminal` を対象にするコマンド)で閉じた 1 回の確認では、ウィンドウは
      `windows` と `terminals` の列挙から無くなったが、シェルと `claude` のプロセスは、tty を持ったまま 2 分以上動作を続け、SessionEnd の hook は実行されなかった
      (エントリは残る。セッションが実行中のためである)。そのシェルに SIGHUP を送ると、`claude` は、制御端末が無い状態で SessionEnd の hook を実行し、
      エントリは、`target` を持たない SessionEnd で無くなった。`close window` で閉じた確認では、この動作は発生していない。原因は確認していない
    - **未検証**: Terminal.app と Ghostty の、タブだけを閉じる操作 / 分割のペインだけを閉じる操作(上記 3 の「ペイン閉じで発火」は、制御端末の有無を記録していない)/
      画面の操作(閉じるボタン、キーの操作)でウィンドウを閉じた場合 / Terminal.app の、実行中のプロセスがあるウィンドウを閉じる前に確認のダイアログを表示する設定での動作
13. **対話でない方法で起動したセッションの判別** — 実機で検証済み(2026-11-23。Claude Code 2.1.330 / macOS 27.2.1。`claude -p` を、一時的な hook の設定
    (`--settings`)で実行し、hook の環境変数、標準入力の項目、親のプロセスを記録して確認):
    - **hook の環境変数**: `claude -p` のセッションの hook は、SessionStart / UserPromptSubmit / Stop / SessionEnd のどれでも、`CLAUDE_CODE_ENTRYPOINT` が `sdk-cli` である。
      対話のセッションの中の Bash ツールから起動した場合も、子のセッションの hook の値は `sdk-cli` である(親の値の `cli` を引き継がない)。対話のセッションでは `cli` である
    - **hook の標準入力**: SessionStart の項目は `cwd`、`hook_event_name`、`session_id`、`source`、`transcript_path` で、起動の方法を示す項目は無い
    - **`claude agents --json`**: 実行中の `claude -p` のプロセスも一覧に含まれ、`kind` は `interactive` である。項目は `cwd`、`kind`、`name`、`pid`、`sessionId`、`startedAt`、`status` で、
      `entrypoint` は無い
    - **`~/.claude/sessions/<pid>.json`**: `claude -p` のプロセスにも作成され、`kind` は `interactive`、`entrypoint` は `sdk-cli` である
    - **transcript**: 発話と添付の行(`type` が `user`、`attachment` など)が `entrypoint` を持ち、`claude -p` の会話では `sdk-cli` である。
      先頭の行(`session-owner`、`queue-operation` など)は、`entrypoint` を持たない
    - **確認できた値**: `cli`(対話)、`sdk-cli`(`claude -p`)、`claude-vscode`(transcript で確認)
    - **`claude -p` で開始した会話を、対話の `claude --resume` で再開した場合**: 再開しただけでは、transcript に `entrypoint` を持つ行は追加されない(`derived-from` の行が 1 つ追加される)。
      発話を送ると、同じ transcript(同じ `sessionId`)に、`entrypoint` が `cli` の行が追記される。新しい transcript は作成されない
    - **未検証**: Agent SDK から起動したセッションの `entrypoint` の値 / 対話の会話を `claude -p --resume` で続けた場合に、同じ transcript に追記されるかどうか

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

### 8.54 ⟳ と Rescan を 1 つの操作 Refresh にして、メニューの項目を減らした

- **決定**: 見出し行の ⟳ と ⌘R は、同じ操作 Refresh を実行する。Refresh は、search の再実行と
  `shiibar-cc reconcile` の両方を実行する(§4.6)。⌄ メニューとアプリメニューの Rescan は廃止する。
  一時表示は `Refreshing…` / `✓ Refresh done` / `Refresh failed` の 1 組にする。
- **理由**: 実行中のセッションと過去の会話を 1 つの一覧に表示している(§8.49)ので、利用者にとっての操作は
  「表示している一覧を最新にする」の 1 つである。変更の前は、⟳ が History の区画だけを、Rescan が Running の区画だけを
  更新し、どちらの区画が古いかを利用者が判断して、操作を選択する必要があった。
- **結果の表示に件数を含めない**: 変更の前の ⟳ は `Updated · N conversations` を表示した。件数は
  search の結果だけの値で、reconcile の結果を表さない。
- **search のエラーは、Refresh の一時表示と別に表示する**: search のエラーは、打鍵による search でも
  発生し、次に成功するまで表示を保持する(§4.6)。Refresh のときだけ別の文言にすると、同じ状態に 2 つの表示ができる。
- **メニューには、画面のほかの場所で提供していない操作だけを含める**: 同じ操作を複数の場所に配置すると、
  有効と無効の切り替えが必要な場所が増える。アプリメニューは、ウィンドウを開いている間だけ表示される(§8.30)ので、
  ポップオーバーだけを使用している間は、アプリメニューの項目を確認できない。
  - ⌄ メニュー: Rescan を除く(⟳ がある)。About、Settings…、Setup Check…、Clear badges、Quit は、
    ポップオーバーとウィンドウの画面に、同じ操作を実行する手段がほかに無いので残す。
  - アプリメニュー: Setup Check…、Rescan、Clear badges を除く。macOS のアプリの決まった場所にある項目
    (About、Settings… ⌘,、Close Window ⌘W、Quit ⌘Q)と Edit メニュー(§8.41)は、ショートカットを
    動作させるためにも必要なので残す。
- **⌘R は、ポップオーバーとウィンドウのキー操作として処理する**: アプリメニューの項目のショートカットでは
  なくなるので、Settings ウィンドウと Setup Check ウィンドウが key の間は、⌘R は動作しない(一覧が無い画面である)。
  ⌘R は、⟳ のツールチップ(`Refresh (⌘R)`)で伝える。
- **この決定が変更する過去の決定**: §8.22 の「手動 Rescan」(Refresh になる)/ §8.25 の ⌄ メニューの構成
  (Rescan が無い)/ §8.40 のアプリメニューの構成 / §8.38 の (10) の「完了後に `Updated · N conversations` を 2 秒出す」。
- **再検討の条件**: reconcile の実行時間が長くなり、search の結果の表示を待たせる状況が生じたとき。

### 8.55 検索欄にフォーカスがある間は、下部パネルのボタンを表示しない

- **決定**: 検索欄にフォーカスがある間は、行を選択していても、下部パネルの Jump / Resume / Branch を
  表示しない(§4.6「下部パネル」)。パネルの高さは変更しない。
- **理由**: 変更の前は、ショートカットの記号だけを消して、ボタンを残していた(ボタンの中にキーを表示する決定は §8.49)。その間の Enter は
  一覧にフォーカスを移す操作で、ボタンが示す操作を実行しない。記号の無いボタンだけが残る表示は、
  キーで実行できるかどうかが分かりにくい。ボタンを表示しなければ、画面に表示しているボタンは、常に Enter と
  ⌘Enter で実行できる。
- **変化する操作**: 検索欄にフォーカスがある間は、選択中の行のボタンを直接クリックできない。
  行をクリックするか、検索欄で Enter を押すと、一覧にフォーカスが移動して、ボタンが表示される。
- **パネルの高さを変更しない**: 高さを変更すると、検索欄のクリックのたびに、一覧の表示範囲が変化する。
- **再検討の条件**: 検索欄にフォーカスがある状態から、マウスだけで実行する操作が頻繁に必要になったとき。

### 8.56 History の行が上限を超えている間は、見出しを `first 100` の形式にする

- **決定**: History に表示する行が上限(§9)を超えている間は、区画の見出しを `History first 100` にする
  (§4.6「Recent の区画」)。上限以下の間は、区画名と行数のままである。
- **理由**: 上限を超えている間の見出しは `History 100` で、会話の全体が 100 件であるように読めた。
  末尾の `N more` の行は、一覧を最後までスクロールしないと表示されない。
- **`first` を使用する理由**: History の並びは、スター付きの会話が先で、その後が新しい順である(§4.6。
  スター付きの会話は、§8.60 で Starred の区画に移した)。
  `latest 100` は、スター付きの古い会話が先頭にある場合に、事実と一致しない。`top 100` は、関連度の順位と
  読める。`first 100` は、並びの先頭からの 100 件という事実と、スターと検索の有無に関係なく一致する。
- **棄却した案**: `History 100 of 1,234`(全体の件数は、見出しでは不要である。表示していない件数は、
  末尾の行が示す)/ `History 100+`(「100 件以上ある」と「100 件を超えて表示している」の 2 通りに読める)。

### 8.57 一覧の行のスピナーを Core Animation で動作させる

- **決定**: working の行のスピナーのグリフの切り替えを、Core Animation のアニメーションで実行する(§4.5「表示中の更新」)。
  グリフ、周期、切り替えの計算式は変更しない(§9)。
- **理由**: 変更の前は、50ms ごとにアプリのメインスレッドで表示を更新していた。working のセッションがある間、
  ポップオーバーまたはウィンドウを表示しているだけで、アプリが CPU を使用し続けた。
  Core Animation のアニメーションは、開始した後の切り替えを、アプリのメインスレッドの外で実行する。
- **切り替えの時刻**: 50ms ごとの更新では、グリフの切り替えが最大 50ms 遅れた。変更の後は、計算式の値が
  変化する時刻に切り替わる。
- **トレイアイコンには適用しない**: トレイアイコンの画像は AppKit が複製して表示するので、
  レイヤーのアニメーションを使用できない(画像を設定するたびの処理は §8.51)。トレイアイコンは静止画のままである。

### 8.58 ピンのアイコンの形を変更し、非アクティブになった時点でポップオーバーを閉じる

- **ピンのアイコン**: 斜めに傾いた画びょうの形にする。ON は、アイコンをアクセントカラーで塗り、ボタンに
  アクセントカラーの 16% の背景を付ける(§4.5「ピン」)。変更の前の ON は、まっすぐ立った画びょうの
  線と塗りだけで、背景が無く、OFF との違いが色だけだった。背景を付けると、ON の状態を
  ボタンの大きさの面で判別できる。
- **ポップオーバーを閉じる処理**: `.transient` の `NSPopover` の中から `NSMenu` を一度開くと、その後は、
  アプリが非アクティブになっても、AppKit がポップオーバーを自動で閉じない(2026-11-17、macOS 27.2、
  `NSPopover` と `NSMenu` だけで構成した確認用のアプリで再現)。⌄ メニューを開いた後に、他のアプリに
  切り替えても、ポップオーバーが表示されたままになった。メニューを開いた後でも
  `NSApplication.didResignActiveNotification` は通知されるので、この通知を受信した時点で、
  アプリがポップオーバーを閉じる(§4.5「ポップオーバー」)。メニューを開いている間は、この通知は
  通知されないので、メニューの操作中にポップオーバーが閉じることは無い。

### 8.59 カードとヘッダの配置を変更し、詳細ページを開く操作を下部パネルに移動した

- **決定**: (1) カードの右に、記号と時間の列を配置する。上が記号(Running の行は状態記号、History の行はスター)、
  下が経過時間である。カードの左端の記号の場所と、3 行目の先頭の `❯` は廃止する(§4.5「一覧は 3 つの区画」)。
  (2) 行の `>` ボタンを廃止し、1 列で詳細ページを開く操作を、下部パネルの View ボタンにする(§4.6「下部パネル」)。
  (3) ⌘ を押しながらのダブルクリックで、Branch を実行する(§4.5「行のダブルクリック」)。
  (4) 2 列のときの右の列の最小の幅を、460pt から 360pt に変更する(§9)。
  (5) 3 行を、上から、ラベル、タイトル、最後の発話の順にする。タイトルはどの行も太字にし、未確認は赤バッジだけで示す
  (§4.5「一覧は 3 つの区画」・「Running の行」)。
  (6) 会話ペインのヘッダを、1 行目 = フォルダラベルと経過時間、2 行目 = タイトルにする(§4.6「会話ペインの表示」)。
  (7) 列の数が変化しても、キーの操作対象を変更しない(§4.5「幅による切り替え」の「幅を変更したとき」)。
  (8) 1 列の詳細ページを表示している間は、一覧のページのビューを Tab の移動先にしない(§4.5「キー操作」)。
- **記号と時間の列の理由**: 変更の前は、カードの左端に記号の場所(20pt)があり、History の行では、
  スターを付けていない行で、この場所が空白だった。経過時間は、ラベルの行(変更の前は 2 行目)の、ラベルの後に表示していた。
  右に列を配置すると、文字の左端も右端も、全部の行で同じ位置にそろう。空白だった幅は、経過時間の表示に使用する。
  ラベルの行はラベルだけになり、長いラベルを省略せずに表示できる範囲が増える。
- **3 行の順序**: 上から、ラベル、タイトル、最後の発話にする。変更の前は、タイトルが 1 行目、ラベルが 2 行目だった。
  場所、タイトル、内容の順になり、タイトルと最後の発話が隣り合う。同じフォルダのセッションが並ぶとき、
  1 行目でまとまりが分かる。タイトルは、どの行も太字にして、小さい文字のラベルと区別する。
  タイトルと最後の発話の間隔を 4pt にして、ラベルとタイトルの 1 組と、最後の発話を区別する(カードの高さは 3pt 増える)。
  **未確認は、赤バッジだけで示す**: 変更の前は、未確認の行だけタイトルを太字にしていた。赤バッジは、
  カードの右上の角にあり、バッジだけで判別できる。
- **記号を上、時間を下にした理由**: 状態記号(20pt)が、1 行目のラベルと 2 行目のタイトルの高さに並ぶので、タイトルと状態を続けて確認できる。
  経過時間は最後の更新からの時間なので、3 行目の最後の発話と同じ高さに配置する。
- **スターの大きさ**: スターは 16pt で、状態記号(20pt)より小さい。状態記号と同じ 20pt では、実機で、スターがカードの中で
  目立ちすぎた。クリックに反応する範囲は、状態記号と同じ 20pt にする。
- **`❯` を廃止した理由**: 会話ペインは、自分の発言を `You` のラベルで示す(§4.6)。`❯` は、画面のほかの場所に
  対応する表示が無い記号になっていた。3 行の役割は、位置で区別できる。
- **View ボタンの理由**: 行の `>` ボタンは、カードの右端の小さい範囲(28 × 26pt)で、狙って押す必要があった。
  同じカードの中で、ボタンの外のクリックは選択、ボタンのクリックは詳細ページの表示で、動作が分かれていた。
  詳細ページを開く操作は、Jump / Resume より使用する頻度が低い。全部の行にボタンを常に表示する代わりに、
  選択中の行を対象にするボタンを、Branch と主ボタンと同じ場所に 1 つ表示する。行の中は、スターを除いて、
  どこを押しても同じ動作になる。マウスで詳細ページを開く操作は、1 回から 2 回(行のクリック → View)に増える。
- **行のクリックで会話を表示する形にしなかった理由**: 一覧を開く目的の多くは、状態の確認と Jump / Resume で、
  会話の内容の確認は必要なときだけである。クリックのたびに会話を表示すると、必要のない表示が増える。
  1 列でクリックを詳細ページの表示にすると、ダブルクリックと区別するための待ち時間も必要になる。
  棄却した案: クリックで詳細ページに移動する / 選択した行の下に会話を表示する(上下に分割)/
  選択した行をその場で展開する / 選択するとポップオーバーを横に広げて会話を表示する。
- **⌘ + ダブルクリックの理由**: キーの規則(Enter は Jump / Resume、⌘Enter は Branch)と同じ対応を、マウスの操作にも適用する。
  Branch を、行から 1 回の操作で実行できる。
- **右の列の最小の幅を 360pt にした理由**: 変更の前は、文字の大きさ 13 のとき、2 列になる幅が 880pt で、
  ポップオーバーの幅(420pt)の約 2.1 倍だった。360pt はウィンドウの最小の幅で、1 列の詳細ページは、
  この幅で会話ペインを表示している。
- **棄却したカードの配置**: 時間だけをタイトルの行の右端に移動する / History だけ左の場所をなくす(区画の間で文字の左端がそろわない)/
  状態記号をタイトルの前に小さく表示する(状態記号が小さくなる)/ カードを 2 行にする / カードの枠をなくす。
- **この決定が変更する過去の決定**: §8.49 の「詳細ページは行の `>` ボタン」(View ボタンになる)。
  あわせて、キーの案内の `→ Open` を廃止し、View ボタンの中に `→` を表示する。
  未確認の行のタイトルの太字(§8.31 が参照している表示)も廃止する。
- **会話ペインのヘッダ**: 1 行目をフォルダラベルと経過時間、2 行目をタイトルにする(§4.6)。変更の前は、1 行目がタイトル、
  2 行目がホーム相対のフルパスと経過時間だった。カードの 3 行の順序(ラベル、タイトル)と同じにして、一覧と会話ペインで、
  場所、タイトルの順序を同じにする。フルパスの代わりにラベルを表示する理由は、カードと同じ文字を表示するためである。
  フルパスは、Resume で開き直すフォルダを確認するために表示していた。末尾 2 要素のラベルで、ほとんどの場合は
  フォルダを判別できる。同じ末尾 2 要素を持つ別のフォルダは、ヘッダでは区別できなくなる。
- **列の数が変化しても、キーの操作対象を変更しない**(§4.5「幅による切り替え」の「幅を変更したとき」): 変更の前は、ウィンドウの幅を変更して
  1 列と 2 列が切り替わると、一覧にフォーカスがある状態でも、検索欄にフォーカスが移動した。1 列と 2 列で、一覧のページを
  別々のビューとして作成していたため、切り替えのたびに検索欄が作成され、作成された検索欄が、過去のフォーカスの依頼
  (ウィンドウを開いたとき、⌘F)を再度実行していた。1 列と 2 列で同じビューを使用して、検索欄を作成し直さないようにした。
- **詳細ページの表示中は、一覧のページのビューを Tab の移動先にしない**(§4.5「キー操作」): 1 列の詳細ページの表示中も、
  一覧のページのビューは、詳細ページの下に残っている。変更の前は、詳細ページで Tab を押すと、表示していない検索欄に
  フォーカスが移動し、検索欄にフォーカスがある間の規則(下部パネルのボタンを表示しない — §8.55)が適用された。
- **再検討の条件**: 会話の内容を続けて確認する使用が増えて、行のクリック → View の 2 回の操作が負担になったとき。

### 8.60 History を Starred と Recent の区画に分割し、区画を開閉できるようにした

- **決定**: (1) 過去の会話を、**Starred**(スター付きの会話)と **Recent**(それ以外の会話)の 2 つの区画に分割して、
  History の見出しの下に表示する。Starred の並びは利用者が決めた順序で、行のドラッグで変更する
  (§4.5「一覧は 3 つの区画」・「行のドラッグ」、§4.6「Starred の区画」・「スター」)。
  (2) Recent から Starred へのドラッグでスターを付け、Starred から Recent へのドラッグでスターを解除する。
  (3) Running、Starred、Recent の区画と History を、見出しのクリックで開閉できるようにする(§4.5「区画の開閉」)。
  (4) 区画の行を、1 つの枠の中に、区切り線で区切って並べる(§4.5「一覧は 3 つの区画」)。
  (5) 検索中は、History の見出しの下に、Starred の行と Recent の行を、1 つの一覧として表示する(§4.6「検索の適用範囲」)。
- **Starred を区画にした理由**: 変更の前は、スター付きの会話を History の先頭に、新しい順で表示していた。
  スター付きの会話と残りの会話の境界が見た目に無く、スター付きの会話の位置は、会話を再開するたびに変化した。
  区画にすると、繰り返し再開する会話が、決まった位置に並ぶ。
- **区画の名前**: スター付きの会話の区画は `Starred` にする。`Pinned` は、ウィンドウのピン(Keep on top)と紛らわしい。
  それ以外の会話の区画は `Recent` にする。新しい順に並ぶことを、名前でも示す。
- **Starred と Recent を、History の見出しの下に表示する理由**: スター付きの会話は、過去の会話の一部である。
  Starred を、Running と History に並ぶ区画にすると、この関係が画面に表示されない。
- **Recent に独自の見出しを付けた理由**: Running、Starred、Recent の見出しは、その見出しの区画の行だけを開閉する。
  History の見出しを Recent の見出しとして使用する形(Starred を、History の見出しと Recent の行の間に表示する形)では、
  History の見出しの行数と山形が、Starred の下にある行を指す。History を閉じても、Starred の表示が残る。
- **Starred に行が無い間は、Starred と Recent の見出しを表示しない理由**: スターを使用していない間に、
  History と Recent の 2 つの見出しが、1 つの区画の上に続くためである。この間は、History の見出しが Recent の見出しを兼ねる。
  兼ねている間の見出しは、History と Recent の両方が開いているときだけ、開いた状態で表示する
  (Recent を閉じている間に Starred の行が無くなった場合に、閉じた行を表示しないためである)。
  閉じた状態の見出しのクリックは、両方を開く(片方だけを開くと、クリックしても行を表示しない場合がある)。
- **行を 1 つの枠の中に並べた理由**: 変更の前は、行が 1 枚ずつの枠(カード)で、行の間に隙間があった。
  1 つの枠にすると、行の間の隙間と枠線が無くなり、一度に表示できる行が増える。区画ごとに 1 つの枠になり、
  区画の境界を判別しやすい。3 つの区画は、同じ形にする。選択中の行は、地の色だけで示す。
- **スター付きの会話が実行中の間は、Running にだけ表示する**: 一覧を開く主な目的は、waiting のセッションの確認である。
  実行中のセッションを Running と Starred の両方に表示すると、waiting の確認で 2 つの区画を確認する必要がある。
  このため、利用者が決めた順序が適用されるのは、実行していない会話だけである。会話が終了すると、Starred の元の位置に戻る。
- **スターを付けた会話は末尾に追加する**: 先頭に追加すると、並べ替えた順序の全体が 1 つずつ下に移動する。
- **区画の間のドラッグ**: 星のクリックで付けたスターは末尾に追加されるので、位置を指定するには、続けて並べ替えが必要になる。
  Recent の行を Starred にドロップすると、1 回の操作で、位置を指定してスターを付けられる。
  Starred から Recent へのドロップでは、位置を示す線を表示せず、Recent の見出しを強調する。
  Recent の中の位置は新しい順で決まり、ドロップした位置には配置されないためである。
- **Starred を表示していない間は、ドラッグでスターを付けられない**: ドラッグを開始した時点で空の Starred の区画を表示すると、
  ポインタの下の行が下に移動する。最初のスターは、星のクリックで付ける。
- **並べ替えはマウスだけにする**: ⌥↑ / ⌥↓ は、詳細ページで前後の会話に切り替えるキーである(§4.5「キー操作」)。
  スター付きの会話の数は少なく、並べ替えの頻度は低い。
- **検索中は、ドラッグできない**: 検索中は、一致する行だけを表示する。表示していない行との前後の関係を、
  ドロップの位置で指定できない。
- **検索中の History を 1 つの一覧にした理由**: 検索は、目的の会話を特定する操作である。Starred の区画を表示しないので、
  並べ替えできない状態であることを、画面で判別できる。スター付きの行を先頭にする理由は、繰り返し使用する会話であるためである。
  検索中の見出しは、開閉できないので、文字だけにする。
- **ドラッグ中の表示の理由**: 挿入位置にならない行を薄く表示し、移動先になる見出しに案内を表示して、移動できる場所を示す。
  ドラッグ中にホバーの表示を付けない理由は、ポインタの下の行が移動先であるように読めるためである。
- **ドラッグできない行で、理由を表示する理由**: 3 つの区画は同じ形で、並べ替えられる区画を、形では区別できない。
  ドラッグできない行では、操作した時点で、理由を示す。
- **見出しの種類の理由**: Running と History の見出しは、帯にする。文字だけの見出しでは、押せる範囲を判別しにくく、
  右端の山形が名前から離れて表示される。帯は、押せる範囲と一致し、山形が帯の中に収まる。
  Starred と Recent の見出しは、History の下の階層であることを示すために、地の無い見出しにする。
- **見出しを選択の対象にしない**: 選択中の行は、下部パネルのボタンと、2 列の右の列の会話を決める(§4.5「行の選択」)。
  見出しを ↑ / ↓ の移動の対象にすると、区画をまたぐたびに、ボタンが消えて、右の列が `No conversation selected` になる。
  Enter の動作も、行では Jump / Resume、見出しでは開閉に分かれる。開閉は、マウスだけの操作にする。
  閉じている History の会話には、検索で到達できる(検索中は、記憶している状態に関係なく、開いた状態で表示する)。
- **検索中は、閉じた状態を適用しない**: History を閉じた状態で検索すると、結果の大半が History にあるので、
  閉じたままでは、見出しだけが表示される。検索中の見出しのクリックは、何もしない。記憶している状態を、
  表示に反映されない操作で変更しないためである。
- **Running の印は、waiting と未確認を区別しない**: 印がある場合の次の操作は、どちらの状態でも、Running を開くことである。
  状態の区別は、トレイアイコンと、開いた後の行の状態記号が示す。
- **閉じている区画の行は、一覧に表示していない行として扱う**: 選択中の行が、閉じている区画に移動した場合(Running を閉じた状態での Resume など)は、
  選択なしになる。表示していない行を選択したままにすると、↑ / ↓ の起点と、詳細ページの位置の表示に、別の規則が必要になる。
- **アニメーションは無い**: 開閉も、ドロップの後の移動も、直後の表示に切り替える。
- **この決定が変更する過去の決定**: §8.49 の「行は 3 行のカード」と、選択中のカードの枠(行は 1 つの枠の中に並べ、選択中の行は地の色で示す)。
  §8.59 の「棄却したカードの配置」のうち、カードの枠の廃止(行ごとの枠を廃止した。区画ごとの枠がある)。
  §8.49 の「Running と History の 2 区画」(3 つの区画と、History の見出しになる)と、スター付きの会話を History の先頭に表示する並び(Starred の区画になる)。
  §3.1 と §8.49 の、赤の用途(閉じている Running の印にも使用する)。
  §8.56 の見出しの形式(`History first 100` は、`Recent first 100` になる。History の見出しが Recent の見出しを兼ねている間は、
  `History first 100` である)。
- **採用しなかったもの**:
  - スター付きの会話を、実行中も Starred に表示する(状態記号を Starred の行に表示する)— 上記のとおり、waiting の確認が 2 つの区画に分かれる
  - 実行中の会話にスターを付ける操作 — Running の行は、星の位置に状態記号を表示する。星を表示する場所が無い
  - ドラッグ中に、ほかの行が移動して隙間を空ける表示 — 移動先は線で示す
  - Starred だけを別の形にする(行を 2 行にする、行ごとの枠にする、区画に背景の色を付ける)— 3 つの区画を同じ形にして、
    区別は、見出しの階層と名前で示す
  - Starred の行に、並べ替えのつまみを表示する — Recent の行もドラッグできるので、つまみの有無が、ドラッグできるかどうかと一致しない
  - Starred を、Running と History に並ぶ区画にする — 上記のとおり、過去の会話の一部であることが表示されない
- **再検討の条件**: 実行中の会話も決まった位置に並べる必要が出たとき(スター付きの会話を、実行中も Starred に表示する形)。
  作業中の会話に、その場でスターを付ける必要が出たとき。キーだけで区画を開閉する必要が出たとき。
  並べ替えられる区画を、操作する前に判別する必要が出たとき(Starred の行に印を表示する形)。

### 8.61 表示の形を記憶し、ウィンドウの形ではトレイアイコンとホットキーでウィンドウを開閉する。Refresh を ⌄ メニューに移動した

- **決定**: (1) 一覧を表示する形(ポップオーバーの形 / ウィンドウの形)を記憶する。`Open in window` でウィンドウの形になり、
  ウィンドウを閉じた後も、トレイアイコンのクリックとグローバルホットキーは、ウィンドウを開く。形は、アプリの再起動の後も保持する
  (§4.5「表示の形」)。(2) ウィンドウの形では、トレイアイコンのクリックとグローバルホットキーは、閉じているウィンドウを開き、
  前面でないウィンドウを前面に移し、前面のウィンドウを閉じる(§4.5「トレイアイコンのクリック」)。
  (3) ウィンドウの見出し行に `Open in popover` を追加し、ピンをその右に配置する(ウィンドウの見出し行の並びは、
  検索欄 / `Open in popover` / ピン / ⌄ である。§4.5「見出し行」)。
  (4) 見出し行の ⟳ を廃止し、Refresh を ⌄ メニューの項目にする。⌘R は残す(§4.5「⌄ メニュー」、§4.6)。
- **形を記憶する理由**: 変更の前は、ウィンドウを閉じると、次のトレイアイコンのクリックとホットキーは、ポップオーバーを開いた。
  ウィンドウで使用する場合は、開くたびに `Open in window` を押す必要があった。
- **形を変更する操作を、2 つのボタンだけにする**: ウィンドウを閉じる操作で形がポップオーバーの形に戻ると、閉じた後のクリックで
  ウィンドウを開く動作にならない。
- **前面のウィンドウを閉じる理由**: ホットキーで一覧を確認して、すぐに元の作業に戻る使い方では、閉じる操作もホットキーで
  実行できる必要がある。ウィンドウは Esc で閉じない(§4.5「ウィンドウ」)ので、変更の前は、キーで閉じる操作が ⌘W だけだった。
  閉じた後は、キーの入力が、直前に前面だったアプリに戻るので、そのまま入力を続けられる。
- **「前面」を、key の状態で判定する**: ホットキーを押す目的は、一覧をキーで操作することである。キーの入力先が一覧でない間
  (ほかのアプリが前面にある、Settings が key である、ピンが ON のウィンドウが手前に表示されているだけである)は、閉じずに
  入力先を移すと、次の操作(↑ / ↓ と Enter)を続けられる。最小化しているウィンドウと、別の Space にあるウィンドウも、
  前面ではないものとして扱う(§4.5「トレイアイコンのクリック」の 4 つの条件)。判定には、クリックまたはホットキーの押下の直前の状態を使用する。
- **起動時には何も表示しない**: 起動時にウィンドウを開くと、ログイン時に起動する設定(§4.5「ログイン時起動」)では、ログインのたびにウィンドウが表示される。
- **`Open in popover` は、ポップオーバーをすぐに開く**: ウィンドウを閉じるだけにすると、続きの操作に、トレイアイコンのクリックが
  もう 1 回必要になる。`Open in window` も、ポップオーバーを閉じて、ウィンドウをすぐに開く。
- **Esc でウィンドウを閉じない規則は、変更しない**: ウィンドウは、開いたまま使用する画面である。キーですぐに閉じる操作は、
  ホットキーで実行できる。
- **`Open in popover` の後は、ポップオーバーを閉じるまで通常アプリのままにする**: ポップオーバーを表示している間に accessory に戻すと、
  アプリが非アクティブになって、表示したばかりのポップオーバーが閉じる可能性がある(この動作は、実機で確認していない。
  通常アプリのままにする方法は、この動作に依存しない)。Dock の表示は、ポップオーバーを閉じるまで残る。
- **通常アプリになる条件は、上の `Open in popover` の場合を除いて、変更しない**(§8.30): ウィンドウの形でも、ウィンドウを開いている間だけ通常アプリになる。
  Jump の後は、ウィンドウが開いたまま背面に残るので、Dock の表示が変化するのは、ウィンドウを開いたとき、`Open in popover` 以外の操作でウィンドウを閉じたとき、
  および `Open in popover` で開いたポップオーバーを閉じたときだけである。
- **Refresh を ⌄ メニューに移動する理由**: 使用する回数の少ない操作が、見出し行の場所を使用していた。
- **メニューの項目に ⌘R を表示する**: ⟳ のツールチップ(`Refresh (⌘R)`)が無くなるので、画面の中で ⌘R を示す場所は、
  この項目だけになる。
- **実行中の表示**: 実行中は、項目の名前を `Refreshing…` にして、disabled にする。メッセージ行の `Refreshing…` と結果の表示は残す。
  ⟳ の回転が無くなるので、メッセージ行が、実行の反応になる。結果の表示が §9 の時間残るので、`Refreshing…` に最低の表示時間は設定しない。
- **実行中の `Refreshing…` を、索引の進捗とエラーより優先して表示する**(§4.6「メッセージ行」): ⟳ が無くなると、メッセージ行が、
  Refresh を実行したことを示す唯一の表示になる。エラーを表示している間に Refresh を実行すると、エラーの表示が優先されて、メッセージ行の表示が変化しない。
  結果の表示(`✓ Refresh done` / `Refresh failed`)の優先順位は、変更しない。
- **アプリメニューには Refresh を追加しない**: アプリメニューの項目は、macOS のアプリの決まった場所にある項目だけである(§8.54)。
- **この決定が変更する過去の決定**: §8.50 の「ウィンドウを開いている間は、ウィンドウを前面に移す」(key のウィンドウも閉じない動作だった)/
  §8.49 の「ウィンドウは `Open in window` で開く」(ウィンドウの形の間は、トレイアイコンのクリックとグローバルホットキーでも開く)と、棄却した
  「トレイアイコンのクリックでウィンドウの表示と非表示を切り替える案」(ウィンドウの形の間は、この動作になる。ポップオーバーは残る)/
  §8.54 の「見出し行の ⟳ と ⌘R」、「⌄ メニューから Rescan を除く(⟳ がある)」、「⌘R は ⟳ のツールチップで伝える」/
  §8.42・§8.43・§8.44 の ⟳ の反応と回転の規則、§8.38 の (10)(対象の ⟳ が無くなる)。
  §8.30(通常アプリになる条件)は、`Open in popover` で開いたポップオーバーを表示している間も通常アプリのままにする点だけを変更する。
  §8.33(ピンの動作)は、変更しない。
- **採用しなかったもの**:
  - ウィンドウを閉じた時点で、形をポップオーバーの形に戻す(上記「形を変更する操作を、2 つのボタンだけにする」)
  - ウィンドウの形で終了した後の起動時に、ウィンドウを開く(上記「起動時には何も表示しない」)
  - ウィンドウの形の間は、ウィンドウを開いていても accessory のままにする: ウィンドウが前面の間も、メニューバーに、ほかのアプリの
    メニューが表示される。⌘Tab でウィンドウに切り替えられない
  - ウィンドウが手前に表示されていれば、key でなくても閉じる(上記「「前面」を、key の状態で判定する」)
  - `Open in popover` を、ウィンドウを閉じるだけの操作にする(上記「`Open in popover` は、ポップオーバーをすぐに開く」)
  - `Refreshing…` に最低の表示時間を設定する(上記「実行中の表示」)
- **再検討の条件**: ウィンドウの形で、ウィンドウを閉じたときと開いたときの Dock の表示の変化が、使用の妨げになったとき
  (§8.30 の再検討の条件と合わせて検討する)。Refresh を実行する回数が増えて、メニューを開く操作が負担になったとき。

### 8.62 2 列の見出し行をウィンドウの幅の全体にし、Refresh を見出し行のボタンに戻し、2 列になる幅を 600pt にする。ピンが ON の間は Settings などを手前に表示する

- **決定**: (1) 2 列のウィンドウの見出し行を、2 つの列にまたがる 1 行にする。検索欄は、信号機ボタンの右から、ボタンの並びの直前まで伸ばし、
  Refresh・`Open in popover`・ピン・⌄ はウィンドウの右端に配置する。会話の中のヒットのカウンタと ‹ › を、検索欄とボタンの並びの間に配置する。2 列では、右の列の検索バー行を表示しない(§4.5「見出し行」、§4.6「ヒットナビゲーション」)。
  (2) ピンが ON で、ウィンドウを開いている間は、Settings ウィンドウ、Setup Check ウィンドウ、About パネルも floating レベルにする(§4.5「ピン(Keep on Top)」)。
  (3) `Open in popover` のアイコンを、メニューバーの線と上向きの矢印がある角丸の四角にする。
  (4) 検索欄の高さを 28pt にする(文字の大きさ 13 のとき。§9)。
  (5) 2 列になる幅を 600pt にする。2 列のときの右の列の最小の幅を、360pt から 320pt に変更し、2 列になる幅を、一覧の列の最小の幅(280pt)と
  右の列の最小の幅の合計にする(§4.5「幅による切り替え」、§9)。
  (6) Refresh を、見出し行のアイコンのボタンにし、⌄ メニューの項目を削除する。⌘R は残す(§4.5「見出し行」、§4.6)。
  (7) 見出し行のボタンと、会話ペインのヘッダの戻るボタンを、文字の大きさに連動させる(大きさは 13 のとき 24pt、アイコンは 13 のとき 15pt。
  §4.5「文字の大きさ」)。
  (8) ウィンドウの見出し行と、ウィンドウの 1 列の詳細ページのヘッダで、上と下の余白を同じ値にする(§4.5「文字の大きさ」の「ウィンドウ」)。
  (9) ウィンドウを全画面にしている間も、見出し行を表示する。全画面の間は、OS のタイトルバーの帯を表示せず、信号機ボタンの分の左の空きを取らない(§4.5「見出し行」)。
- **見出し行を 2 つの列にまたがる形にする理由**: 検索は、一覧の絞り込みと、会話の中のヒットの両方に適用される。見出し行が左の列の中にあると、
  一覧だけに適用される検索として読める。また、ボタンが列の境界の近くにあり、会話を表示している領域に隣接していた。
- **検索欄を、ボタンの並びの直前まで伸ばす理由**: ポップオーバーと 1 列のウィンドウと同じ規則になる。1 列と 2 列が切り替わるときに、
  検索欄の幅が、切り替えだけを理由に変化しない(ウィンドウの幅の変化の分だけ変化する)。幅の上限と、見出し行の要素が収まらない場合の規則を、
  定める必要が無い。幅の広いウィンドウでは検索欄が長くなるが、ブラウザのアドレスバーと同じ構造である。
- **カウンタと ‹ › を見出し行に配置する**: 検索文字列とヒットの位置が 1 行に並ぶ。右の列の行が 1 つ減り、会話を表示する領域が広くなる。
  1 列の詳細ページには見出し行が無いので、検索バー行は変更しない。
- **Settings などを floating レベルにする理由**: メニューで選択したウィンドウが、ピンが ON のウィンドウの後ろに開くと、選択の結果が画面に表示されない。
  ウィンドウを閉じている間は、手前に表示する対象が無いので、通常のレベルにする(ピンの値は、ウィンドウを閉じても保持するため、
  値だけで判定すると、ポップオーバーの形で使用している間も、Settings などがほかのアプリのウィンドウより手前に表示される)。
- **2 列になる幅を 600pt にする理由**: 変更の前は、2 列になる幅が、一覧の列の既定の幅に 360pt を加えた値(文字の大きさ 13 のとき 780pt)だった。
  ポップオーバーの幅(420pt)から 780pt までの 1 列のウィンドウは、行の右側が空くだけで、会話を読むには詳細ページへの切り替えが必要だった。
  一覧と会話を同時に表示できる幅では、2 列にする。一覧の列の最小の幅(280pt)は、列の境界のドラッグで選択できる幅なので、一覧の表示は成立する。
  600pt から「一覧の列の幅 + 320pt」までのウィンドウでは、右の列が 320pt で、残りが一覧の列になる。
  2 列になる幅は、文字の大きさと、一覧の列の既定の幅に依存しない値になり、文字の大きさの変更で列の数が変化しなくなる。
- **Refresh を見出し行のボタンにする理由**: Refresh は、一覧の内容に対する操作である。メニューでは、メニューを開く操作と項目を選択する操作の
  2 回が必要で、ボタンでは 1 回で実行できる。実行中の状態(アイコンの回転)が、操作した位置に表示される。
  ボタンの並びの左端に配置する(Refresh は一覧の内容に対する操作で、右の 3 つは画面に対する操作なので、検索欄に近い側にする)。
  見出し行の幅は、ボタンが 1 つ増えても不足しない。最小の幅のウィンドウ(360pt)でも、文字の大きさ 13 のとき、検索欄に約 130pt が残る。同じ操作を画面の 2 か所に配置しないので、メニューの項目は削除する(§8.54 の、メニューには、
  画面のほかの場所で提供していない操作だけを含める規則)。メッセージ行の `Refreshing…` と結果の表示、その優先順位は、変更しない。
- **見出し行のボタンを文字の大きさに連動させる理由**: 固定のままでは、文字を大きくしたときに、検索欄だけが大きくなり、同じ行のボタンとアイコンが
  相対的に小さくなる。文字を大きくする目的(見やすさ)は、アイコンにも該当する。ホバーの地の角の半径と、ボタンの左右の間隔は、
  ほかの角の半径と左右の間隔と同じく固定にする。OS が描画する部品(信号機ボタン、‹ › のセグメント)は、大きさを変更できないので固定のままである。
- **ウィンドウの見出し行の上と下の余白を同じ値にする理由**: 内容の上下の中心を信号機ボタンの中心にそろえるので、上の余白は内容の高さで決まる。
  下の余白は、文字の大きさに連動する別の値だったので、検索欄の上と下の余白が一致しなかった(文字の大きさ 13 のとき、上 12pt、下 8pt)。
  下の余白を上の余白と同じ値にすると、見出し行の領域が、信号機ボタンの中心に対して上下が対称になる。内容が高い場合に余白が無くならないように、
  余白の下限を 6pt にする。ポップオーバーには信号機ボタンが無いので、変更しない。
- **アイコンを変更する理由**: 上の辺に矢印の突起がある四角(ポップオーバーの輪郭)は、16pt の大きさでは突起を判別できなかった。
  行き先(メニューバー)を示す図にした。
- **§8.61 の実装で見つかった不具合**: Settings ウィンドウと Setup Check ウィンドウを開く処理は、ポップオーバーを最初に表示したときにだけ
  設定していた。§8.61 で、ポップオーバーを表示せずにウィンドウを開けるようになったので、その場合に、ウィンドウの ⌄ メニューの Settings… と
  Setup Check… が何もしなかった。ウィンドウを表示したときにも設定する形にした。
- **ウィンドウの最小の大きさの不具合**: ウィンドウに設定した最小の大きさ(§9)は、ウィンドウの内容が SwiftUI のビュー(`NSHostingView`)である場合、
  ウィンドウを表示した時点で 0 になり、ウィンドウを最小の大きさより小さくできた(2026-11-20 に、同じ構成のウィンドウを作成するスクリプトで確認)。
  大きさを変更するたびに制限する形にし、記憶した大きさが最小の大きさより小さい場合は、開くときに最小の大きさにする。
- **この決定が変更する過去の決定**: §8.61 のウィンドウの見出し行の並び(検索欄 / `Open in popover` / ピン / ⌄。2 列では、上記の並びになる)と、
  §4.5「見出し行」の `Open in popover` のアイコンの形(上の辺に矢印の突起がある角丸の四角だった)。§8.38 の検索バー行のうち、2 列での表示(1 列の詳細ページは変更しない)。
  §8.33 の、ウィンドウレベルだけを変更する規則は、対象に Settings ウィンドウ、Setup Check ウィンドウ、About パネルのレベルが加わる。
  文字の大きさの規則(§4.5「文字の大きさ」)のうち、2 列の右の列のヘッダの上下の位置(上下の中心を上端から 27pt に固定していた)と、
  検索欄の高さ(24pt だった)、見出し行のボタンと戻るボタンとそのアイコンを固定の寸法にしていた分類(連動する寸法になる)、
  ウィンドウの見出し行と 1 列の詳細ページのヘッダの下の余白(連動する別の値だった)。§8.52 の「比率で連動する寸法と固定の寸法を分ける」は変更しない
  (連動するのはアイコン、固定は左右の余白と角の半径と枠線、という分け方に、見出し行のボタンのアイコンを合わせる)。§8.59 の (4)(右の列の最小の幅 360pt。320pt になる)。§8.53 の「2 列になる幅は、既定の幅から計算する」
  (一覧の列の最小の幅から計算する、一定の値になる)。
  §8.61 の (4)(見出し行の ⟳ を廃止し、Refresh を ⌄ メニューの項目にする)は、見出し行のボタンに戻る。§8.61 は、使用する回数の少ない操作が
  見出し行の場所を使用していることを理由にしたが、2 列の見出し行がウィンドウの幅の全体になり、1 列でも検索欄の幅が残るので、場所の不足は無い。
  §8.61 の「メニューの項目に ⌘R を表示する」と、メニューの項目の実行中の表示(`Refreshing…`、disabled)は、項目と一緒に無くなる。
  §8.42・§8.43・§8.44 の ⟳ の回転の規則(最低 1 回転、回転の切れ目で終了、周期 0.6 秒)は、復活させない。アイコンは、Refresh の実行中だけ、
  1 秒で 1 回転の等速で回転し、終了した時点で静止の形に戻る(§9)。
  ⌘R は、Refresh のボタンのツールチップ(`Refresh (⌘R)`)で示す(メニューの項目が無くなるので、画面の中で ⌘R を示す場所は、このツールチップだけになる)。§8.61 の「実行中の `Refreshing…` を、索引の進捗とエラーより
  優先して表示する」は変更しない。§8.61 の再検討の条件のうち、Refresh についての条件(メニューを開く操作が負担になったとき)は、この決定で解消する。
- **全画面で見出し行を表示する理由**: 見出し行はタイトルバーの領域の中に描画するので、全画面で OS が表示する不透明のタイトルバーの帯に隠れて、
  検索欄と見出し行のボタンを操作できなかった。全画面は、2 列で会話を広く表示する用途があるので、禁止せずに対応する。
  帯を表示しないので、全画面の間は、信号機ボタンは、ポインタを画面の上端に移動したときだけ表示される(OS の標準の動作)。
- **再検討の条件**: 見出し行のボタンが増えて、または文字を大きくして、最小の幅のウィンドウで検索欄の幅が不足したとき。
  幅の広いウィンドウで、検索欄が長いことが、使用の妨げになったとき(幅の上限を設定する)。
  文字を大きくしたときに、1 列の詳細ページのヘッダの領域が 52pt より高くなり、一覧のページの見出し行と高さが違うことが、使用の妨げになったとき。ピンが ON で、ウィンドウを開いている間に、Settings などがほかのアプリのウィンドウより手前に表示されることが、使用の妨げになったとき。
  右の列が 320pt のときに、会話の本文の折り返しが多く、読むことが難しいとき。1 列のまま、600pt より広い一覧を使用する必要が生じたとき。

### 8.63 区画の見出しを幅いっぱいの帯にし、会話を Archive できるようにする

- **決定**: (1) Running と History の見出しを、一覧の幅いっぱいの帯にする(角を丸めず、上端と下端に区切り線を引く)。Starred と Recent の見出しは、
  名前と行数の右に細い線を引く、地の無い見出しにする。一覧の最初の帯は、見出し行のすぐ下に配置する(§4.5「一覧は 3 つの区画」、§9)。
  一覧の地を、行の枠の地に近い明るさにし、帯の地を、その上で判別できる淡い灰色にする(色の規則は `docs/window-design.html` の「実装ノート」)。
  (2) 行の記号と時間の列を、列の右端にそろえる。History の行の列の上は、左からスター、三点リーダーのボタンにする(§4.5「一覧は 3 つの区画」)。
  (3) 三点リーダーのメニューの `Archive` で、会話を通常の一覧から外す。Archive した会話は、⌄ メニューの `Archived` で表示する
  Archive の一覧に表示し、`Unarchive` で戻す(§4.6「Archive」「Archive の一覧」)。
  (4) Archive の一覧は記憶しない(閉じると通常の一覧に戻る)。通常の検索は、Archive した会話を表示しない。
  (5) Running の行と、live の会話の行は Archive できない。Archive した会話が live になったとき(同じ session_id の Running の行がある、
  または search の結果が live と報告している)は、Archive を解除する。Archive するとスターを解除する。
- **帯を幅いっぱいにする理由**: 端から端までの帯と線は、区画の境目として、角丸の行の枠と形で区別できる。角丸の帯は、
  行の枠と同じ幅と同じ角の形なので、行の枠の 1 つとして読める場合があった。Starred と Recent は History の中の区分なので、帯にせず、
  線で区切るだけにして、2 段の関係を形で示す。
- **検索中も帯の形を変更しない理由**: 検索中の見出しは開閉できないが、帯を文字だけの見出しにすると、検索の開始と終了のたびに、
  一覧の上端の形と行の位置が変化する。開閉できないことは、山形を表示しないことで示す。
- **記号と時間の列を右端にそろえる理由**: History の行は、列の上に 2 つの記号を表示する。列の中央にそろえる規則のままでは、
  経過時間が 2 つの記号の間の位置になり、Running の行の状態記号と、History の行の記号の位置の関係が定まらない。右端にそろえると、
  三点リーダー、Running の行の状態記号、経過時間の右端が、すべての行で同じ位置になる。
- **三点リーダーのボタンにする理由**: 常に表示するボタンは、何も操作していない画面で、行に対する操作の場所を示す。
  ポインタを重ねた間だけ表示するボタンは、重ねるまで操作の存在が分からない。メニューを開いてから項目を選択する 2 回の操作なので、
  1 回のクリックでは Archive されず、取り消しの表示を必要としない。行の右クリックのメニューは追加しない(三点リーダーが同じ役割を持つ。
  Resume、Branch、スターは、下部パネルと行の星で操作できる)。キー操作は追加しない(Archive は、頻繁に実行する操作ではない)。
- **Archive の一覧を ⌄ メニューで開く理由**: Archive した会話は、削除されるまで増え続け、普段は表示する必要が無い。
  見出し行のボタンにすると、使用する回数の少ない操作が、常に見出し行の場所を使用する。メニューの項目は、Archive した会話が無い間は disabled にして、
  表示する内容が無いことを示す。
- **Archive の一覧を記憶しない理由**: Archive の一覧は、Running の行を表示しない。表示を記憶すると、次に開いたときに、
  waiting のセッションが一覧に表示されない。
- **Archive の一覧の先頭を、戻る操作を持つ帯にする理由**: メニューで切り替えた表示は、現在の表示が Archive であることと、
  通常の一覧に戻る方法を、画面の中で示す必要がある。帯の `‹ Archived` と、検索欄のプレースホルダの `Search archived` が、この 2 つを示す。
- **切り替えても検索欄の文字を変更しない理由**: 通常の一覧で見つからなかった会話を、同じ文字列で、Archive の一覧から検索できる。
- **実行中の会話を Archive できない理由と、live になったときに解除する理由**: 実行中のセッションを一覧から外すと、waiting の状態に気付けない。
  Archive した会話を再開した場合、その会話は使用中の会話である。Archive したままにすると、終了した後に、通常の一覧に表示されない。
  解除の条件を「Running の行が現れた時点」という出来事ではなく、「live の会話は Archive の一覧に含めない」という状態の規則にする。
  出来事で定めると、アプリの起動の時点ですでに実行中の会話と、Running の行が後から session_id を持つ場合が、規則から漏れる。
  search の結果の live も条件にするのは、対応外のターミナルで再開した会話が Running の行にならず、Archive のまま表示されない状態を避けるためである。
- **Archive するとスターを解除する理由**: スターは会話を手元に置く印で、Archive は会話を片付ける操作である。両方の状態を持たせると、
  Unarchive した後の Starred の中の位置を決める規則が必要になる。
- **Archive をアプリの表示設定として保存する理由**: スターと同じである(索引 DB は自動で再構築されるキャッシュで、transcript は Claude Code が所有する。§4.6「スター」)。
- **検討して採用しなかった案**:
  - Archive の一覧を開くボタンを、見出し行に配置する(上記「Archive の一覧を ⌄ メニューで開く理由」)
  - 行にポインタを重ねた間だけ、Archive のボタンを表示する(上記「三点リーダーのボタンにする理由」)
  - 下部パネルに Archive のボタンを追加する(下部パネルは、会話を使用する操作 — Resume、Branch、Jump — の場所である。
    会話を片付ける操作を並べると、押し間違えたときの影響が大きい)
  - 行の右クリックのメニューを追加する(上記「三点リーダーのボタンにする理由」)
- **この決定が変更する過去の決定**: §8.60 の見出しの種類(角丸の帯を、幅いっぱいの帯にする。文字だけの見出しを、文字と線の見出しにする)と、
  検索中の見出しを文字だけにする規則(帯の形のままにする)/ §8.59 の、記号と時間を列の中央にそろえる規則(右端にそろえる)と、
  History の行の記号をスターだけにする規則(スターと三点リーダーにする)。
- **再検討の条件**: 三点リーダーの分だけ行の文字の幅が狭くなり、タイトルの省略が、使用の妨げになったとき。
  Archive を実行する回数が増えて、メニューを開く操作が負担になったとき(キー操作、複数の行の選択を検討する)。
  Archive した会話が増えて、Archive の一覧の上限(§9)の中で目的の会話を探すことが難しくなったとき。
  Archive の一覧を表示している間に、Running の行が表示されないことが、使用の妨げになったとき。

### 8.64 人の発話が無い transcript を、会話として扱わない

- **決定**: 発話列に人の発話が 1 つも無い transcript は、索引に会話として登録しない。`search` の結果に含まれず、`show` は、
  索引に無い session-id と同じ結果を返す。後から発話が追加されたファイルは、次の追いつきで登録する(§4.4、§4.6「索引の内容」「追いつき」)。
- **理由**: Claude Code は、発話を送らずに終了したセッション(スラッシュコマンドだけを実行したセッション、起動時の指定の誤りで終了したセッション)でも、
  transcript を作成する。このファイルには、表示できる発話が無い。タイトルは、名前を付けるコマンドで設定した場合を除いて無く、
  cwd を記録した発話の行が無い場合は cwd も無い。一覧では、文字の無い行、またはフォルダの名前だけの行になり、開いても何も表示されず、
  cwd が無い行は Resume も Branch も実行できない。
- **`search` だけで除外しない理由**: `search` には無いが `show` では取得できる会話、という状態を作らない。
  「人の発話が無いファイルは会話ではない」という 1 つの規則にすると、一覧の行数、Recent の上限、スター、Archive のどれも、この種類のファイルを考慮する必要が無い。
- **判定を索引に配置する理由**: 発話列を作成するのは索引であり、アプリとスクリプトの両方が、同じ結果を受け取る(§4.6 の、消費者は 2 つという前提)。
- **ファイルの `(パス, mtime, サイズ)` を記録する理由**: 追いつきは、索引に無いファイルを、変化したファイルとして読み直す。
  記録しないと、会話として登録しないファイルを、追いつきのたびに読み直すことになる。
- **Running の行への影響**: Running の行は daemon の一覧で表示するので、発話をまだ送っていないセッションも表示する。
  その行の会話ペインは、`No conversation to show` を表示する(§4.6「会話ペインの表示」)。
- **この決定で表示されなくなる会話**: 名前だけを付けて、発話を送っていない会話は、一覧に表示しない。ターミナルで `claude --resume` を実行すると再開でき、
  発話を送った時点で、一覧に表示する。
- **この決定が変更する過去の決定**: §4.4 の `last_prompt` の「人の発話が無ければ null」の規則(人の発話が無い transcript は結果に含まれないので、
  この場合が無くなる。型は null 許容のままにする)/ Running の行の会話で show が exit 2 のときの表示(エラーの 1 行を、`No conversation to show` にする)。
- **再検討の条件**: 人の発話が無く、Claude の返答だけがある transcript を、一覧から開く必要が生じたとき。

### 8.65 実行中の会話を会話ペインで更新し、Settings の行の形と一覧の色を変更し、コピーの反応に文字を加える。Setup Check を Settings のタブにし、waiting と未確認を別の色で示す。アプリが作成していないウィンドウをログに記録する

- **決定(会話ペインの再読み込み)**: Running の行の会話を表示している間、セッションの状態が変化した時点と、ポップオーバーまたはウィンドウの表示を開始した時点で、
  会話ペインを再度読み込む。Refresh では、表示している会話の種類に関係なく、再度読み込む(§4.6「会話ペインの再読み込み」)。
- **理由**: 会話ペインの内容は、行を選択した時点のもので、その後に送った発話と Claude の返答は、別の行を選択して戻るまで表示されなかった。
  実行中の会話を表示したままで応答を待つ使用では、応答が完了しても画面が変化しない。
- **状態の変化を契機にする理由**: 状態の変化は、daemon が既に通知している(発話の送信、応答の完了、許可の待ちで変化する)。この時点で読めば、
  読む必要があるのは、発話と返答が増えた時点だけになり、ファイルの監視と定期的な再取得を追加しない。応答の途中の文字は表示しない
  (会話ペインは、会話を読み返す場所であり、進行中の出力は、ターミナルで読める)。
- **契機 1 の後にもう 1 回再読み込みする理由**: 状態の変化の通知の時点で、その発話と返答が transcript に書き込み済みであるかどうかは、
  確認していない。書き込みが通知より後になる場合は、通知の時点の再読み込みでは表示されないので、§9 の時間の後に、もう 1 回再読み込みする。
- **index を別のプロセスとして実行し、結果を表示しない理由**: 状態の変化は、利用者の操作ではない時点で発生する。その index の進捗とエラーを
  一覧に表示すると、会話を読んでいる間に、一覧の表示が変化する。ポップオーバーまたはウィンドウを開いたときの index と互いに中止しないのは、
  どちらの後続の処理(search、show)も実行するためである。
- **Running の行の会話の最初の読み込みで index を先に実行する理由**: show は追いつかないので、ポップオーバーまたはウィンドウを表示している間に
  進んだ会話を、行を選択した時点で、最新の内容で表示するためである。History の行の会話は、search の追いつきの後に変化しないので、show だけを実行する。
- **search を再実行しない理由**: 状態の変化のたびに search を再実行すると、会話を読んでいる間に、History の並びが変化する。
  `conversations index` で索引だけを最新にし、`show` で 1 つの会話だけを取得する。`show` に `updated_at` を追加するのは、
  search の結果を使用せずに、終端マーカーの経過時間を求めるためである(§4.4)。
- **スクロールの規則の理由**: 末尾を表示している間は、新しい返答を読むために、新しい末尾に移動する。途中を表示している間は、
  過去の発言を読んでいるので、位置を変更しない。
- **失敗したときに表示を維持する理由**: 再読み込みは、利用者の操作ではない契機でも実行する。読めていた会話を、エラーの表示に置き換えない。
- **「search の結果の更新そのものは、会話ペインの表示を変更しない」規則との関係**: この規則は変更しない(§4.6「表示の状態規則」)。
  会話ペインを更新する契機を、再読み込みの 3 つの契機として、別に定める。History の行の会話は、Refresh のときだけ再度読み込む。
- **決定(Settings ウィンドウの見た目)**: グループのフォーム(`Form` + `.formStyle(.grouped)`)をやめ、見出し付きの枠と、
  「左にラベルと 1 行の説明、右に幅を固定したコントロール 1 つ」の行にする。Appearance は、ポップアップからセグメントにする。
  項目、保存先、動作は変更しない(§4.5「Settings ウィンドウ」)。
- **理由**: すべての行に説明を付けて、その設定で何が起きるかを、操作する前に読めるようにする。右の列の幅を固定すると、
  コントロールの位置が行によって変化しない。3 択の Appearance は、セグメントにすると、選択肢と現在の値を、開かずに読める。
  エラーと案内の文字は、説明と区別できる色にする。
- **この決定が変更する仕様**: §4.5「Settings ウィンドウ」の見た目(グループのフォーム)。§8.26 の決定(独立したウィンドウにすること、
  閉じるボタンを配置しないこと、値を選択した時点で反映すること)は、変更しない。
- **決定(一覧の色)**: ライトの一覧の地を、`controlBackgroundColor` に `systemGray` を 10% 混ぜた色にし、見出しの帯を、不透明度 0.12 にする。
  ダークは、行の枠の地を、白の不透明度 0.10 にし、見出しの帯を、不透明度 0.08 にする(window-design.html「実装ノート」)。
- **理由**: ライトでは、一覧の地と行の枠(白)の明るさが近く、行の枠の範囲を読み取りにくい。行の枠の線を濃くすると、行の間の区切りの線と
  同じ強さになるので、地を濃くして差を付ける。帯は、地よりも濃くして、地との差を保つ。ダークでは、行の枠と帯の明るさが近いので、
  行の枠を明るくし、帯を地に近付けて、地、帯、行の枠の順に明るくする。
- **決定(コピーの反応)**: 発言ごとのコピーのボタンを押したときに、チェックマークに加えて、アイコンの左に `Copied` を 1 秒間表示する。
  チェックマークの時間も 1 秒にする(§4.6「発言ごとのコピー」、§9)。
- **理由**: アイコンの形の変化は 14pt の範囲で、押した直後にポインタの下にあるので、変化に気付きにくい。文字の表示は、ポインタの横に表示され、
  コピーが実行されたことを読める。表示の時間は、文字を読むのに必要な長さにし、同じボタンを続けて使用するときに、前の表示が残らないようにする。
- **決定(Setup Check を Settings のタブにする)**: Settings ウィンドウに、`General` と `Setup Check` の 2 つのタブを配置し、
  Setup Check の内容を、2 つ目のタブに表示する。独立した Setup Check ウィンドウと、⌄ メニューの `Setup Check…` をやめる。
  確認は、タブを表示するたびに実行する(§4.5「Setup Check のタブ」)。
- **理由**: Setup Check は、導入の状態を確認する画面で、使用するのは、導入の直後と、動作に問題があるときである。設定と同じウィンドウにあると、
  探す場所が 1 つになる。⌄ メニューは、普段使用する項目(Archived、Mark all as read)が中心になり、項目が 1 つ減る。
  行の形と枠を General のタブと同じにするのは、同じウィンドウの中で、見た目の規則を 1 つにするためである。
  開くたびに `General` を表示するのは、Settings… を選択する目的の大半が、設定の変更のためである。
- **この決定が変更する仕様**: §4.5 の Setup Check ウィンドウ(独立したウィンドウ、グループのフォーム、⌄ メニューの項目)。
  §8.62 の「ピンが ON の間は Settings などを手前に表示する」の対象は、Settings ウィンドウと About パネルになる。
- **決定(waiting と未確認の色)**: waiting を、オレンジ(`systemOrange`)の状態記号で示し、未確認を、アクセントカラーの点で示す。
  閉じている Running の印と、トレイアイコンの点は、waiting があればオレンジ、無くて未確認があればアクセントカラーにする。
  アプリアイコンの点は、固定の青にする(§3.1、§4.5、§9、menubar-design.html)。
- **理由**: 変更の前は、色は赤の 1 つで、未確認だけを示していた。waiting のセッションは、確認した後(未確認が消えた後)は、色が無くなり、
  操作を待って止まっているセッションと、待機中のセッションを、記号の形だけで区別していた。操作を待っているセッションは、
  確認が済んだだけのセッションよりも、先に対応する必要があるので、waiting である間は、確認済みかどうかに関係なく、色で示す。
  未確認は、「まだ読んでいない」ことを示すので、未読の表示として一般的な、アクセントカラーの点にする。
  waiting を赤ではなくオレンジにするのは、赤は、エラーまたは失敗として読まれやすく、waiting は、故障ではなく、操作の待ちのためである。
  オレンジと青は、色覚の特性にかかわらず、区別しやすい組み合わせでもある。
- **トレイアイコンの点でオレンジを優先する理由**: トレイアイコンは、全セッションを 1 つの表示にまとめるので、点は 1 つである。
  waiting と未確認の両方がある場合は、先に対応する必要がある waiting を示す。
- **アプリアイコンの点を青にする理由**: 赤い点は、変更の前の、未確認の色に合わせたものである。一覧とトレイアイコンで、未確認が
  アクセントカラーになるので、アイコンの点も、既定のアクセントカラーに近い青にする。アイコンの画像は、アクセントカラーの設定に追従できないので、固定の値にする。
- **`Clear badges` を `Mark all as read` にする理由**: 項目が消すのは、未確認の点だけで、waiting のオレンジは消えない。
  「バッジ」は、2 つの色の点のどちらを指すかが読み取れないので、動作(すべてを既読にする)を名前にする。動作は変更しない。
- **この決定が変更する仕様**: §8.29 と menubar-design.html の「色は赤の 1 つで、未確認だけを示す。状態には色を使用しない」
  (waiting にオレンジを使用し、未確認の色をアクセントカラーにする。working と idle に色を使用しない点は、変更しない)/
  §8.24 の項目の名前 `Clear badges`(動作と、通知センターの通知を変更しない点は、変更しない)/ §8.60 の Running の印(waiting と未確認を、色で区別する)。
- **決定(アプリが作成していないウィンドウの記録)**: アプリのプロセスの中に、アプリの通常の操作で表示されるウィンドウ以外のウィンドウが表示されたときに、
  クラスの名前、大きさ、ウィンドウレベルを os_log に記録する。記録するだけで、動作は変更しない(この記録は、§8.68 で削除した)。
- **理由**: システムが、アプリのプロセスの中にパネルを表示する場合がある。そのパネルがどの機能のものかは、外からは、位置と大きさしか分からない。
  クラスの名前をログに記録すると、意図しないパネルが表示されたときに、ログで機能を特定できる。
- **再検討の条件**: 応答の途中の文字を会話ペインで読む必要が生じたとき / 状態が変化しない間に発話が増える使用
  (応答の途中に次の発話を送る、など)で、表示の遅れが問題になったとき / transcript への書き込みが、契機 1 の後の再読み込み(§9 の時間)よりも
  遅れて、発話または返答が表示されない場合があると判明したとき / メニューバーの上で、アクセントカラーの点を、背景の色と判別できない
  アクセントカラーの設定があると判明したとき(トレイアイコンの点を、固定の色にすることを検討する)/ 導入の問題に気付く経路として、
  ⌄ メニューの項目が必要になったとき。

### 8.66 対応ターミナル以外のセッションを追跡し、Ghostty に対応し、Resume のターミナルを設定にし、行の選択で未確認を下ろす(M56)

- **決定(対応ターミナル以外のセッションの追跡)**: 対応ターミナルの target を導出できない、ターミナルで実行しているセッションを、
  `process:<pid>` の target で追跡する(§2・§3.4・§3.5・§3.6・§4.1)。状態の表示、未確認、通知、音、トレイアイコンの集計は、ほかのセッションと同じである。
  できないのは、タブへのジャンプだけである(主ボタンは disabled の Jump。Branch は押せる)。
- **理由**: §8.11 の時点では、アプリの機能は「状態を見る」と「タブに飛ぶ」の 2 つで、飛べないセッションは、一覧に表示しても使用できなかった。
  その後、waiting と完了の通知、会話ペインでの会話の閲覧(実行中の会話の更新を含む — §8.65)、Branch が加わり、
  飛べないセッションでも、許可待ちに気付く、返答を読む、分岐する、という使用ができる。追跡しない場合、これらが、ターミナルの種類だけを理由に使用できない。
- **鍵を、`claude` のプロセスの pid にする理由**: 対応ターミナルの target は、タブ(端末)を鍵にしていて、同じタブでの `/clear` と、セッションの中での resume の後も、
  target は同じである(§7-3・§7-4)。ターミナルに依存しない鍵で、同じ性質を持つのは、そのタブで実行している
  `claude` のプロセスである。`session_id` を鍵にすると、`/clear` のたびに target が変化し、同じ `session_id` を 2 つのプロセスが resume している場合に、
  2 つのセッションが 1 つのエントリになり、入れ子のセッション(下記)が、親とは別のエントリになる。
  pid は、hook(祖先 walk)と reconcile(`claude agents` の一覧)の両方から導出できる(同じ値になることは、iTerm2 と Ghostty で実測 — §7-9)。
  target の項目に prefix を付けて入れるので、daemon の検索、アプリの行の識別、通知の識別は、target のままである。
  ジャンプできるかどうかは、クライアントが prefix で判定する(未知の prefix を「ジャンプできない」に分類するので、ターミナルを追加したときにも成立する)。
- **ターミナルを持たないセッションは追跡しない**: 制御端末を持つ祖先が無い report は drop し、reconcile は tty を持たない pid を送らない。
  対象は、この規則で決まる(エディタの拡張機能、常駐プロセスが起動する実行など)。利用者が画面で操作するセッションではなく、
  それぞれを Running の行と完了の通知にすると、利用者の番を示す表示が埋もれる。
- **決定(制御端末を持つ祖先が無い SessionEnd は、`target` を持たない report として送り、`session_id` でエントリを削除する)**(§3.6「`target` を持たない SessionEnd」):
  ターミナルのウィンドウを閉じて終了したセッションでは、SessionEnd の hook の時点で、制御端末が無い(§7-12 の実測。iTerm2、Terminal.app、Ghostty で同じ)。
  この report を drop すると、ウィンドウを閉じたセッションの行は、次の定期の reconcile の prune(約 1 分)まで残る。
- **理由(pid ではなく `session_id` で決める)**: `session_id` は、エントリが保持し、`state.json` にも保存していて、target の付け替えと daemon の起動の後も、
  report の値と一致する。pid は、制御端末が無い状態では、祖先の連鎖の中のどのプロセスが対象の `claude` であるかを、hook の側で判定できない
  (祖先 walk は、制御端末を持つことを目印にしている)。`session_id` の一致だけで決めるので、入れ子のセッションの SessionEnd が、親のエントリを削除することも無い。
  一致するエントリが無い場合に登録しないので、ターミナルを持たないセッションを追跡しない規則(上記)は、変化しない。
  送るのを SessionEnd だけにするのは、ほかのイベントでは、エントリを登録または更新するための target が必要で、制御端末が無い状態では導出できないためである。
- **入れ子のセッションの report を無視する**(§3.6「入れ子のセッション」): 実行中のセッションの Bash ツールが起動した `claude -p` の hook は、
  祖先 walk が親の `claude` に到達するので、親と同じ pid、同じ target で、子の `session_id` を持つ report を送る(§7-9 の実測)。
  適用すると、親が作業中でも、子の Stop で完了の通知が発生し、子の SessionEnd で親の行が消える。pid が同じで `session_id` が異なる report を、
  同じプロセスの中でのセッションの切り替え(`source` が `clear` または `resume` の SessionStart)を除いて、無視する。
  判別に使用できる値は、pid と `session_id` だけである(hook の内容には、入れ子であることを示す項目が無い)。
  対応ターミナルの target にも、同じ規則を適用する(iTerm2 では、相続した `ITERM_SESSION_ID` によって、子の report が親のエントリを上書きしていた — §7-3)。
  pid で判定できない間(daemon の起動の後)と、子が `resume` で起動された場合は、子の report を適用する。次の reconcile が、`claude agents` の一覧の内容でエントリを上書きするので、
  この間隔での誤りは、受け入れる。
  `/clear` で、SessionEnd がエントリを削除して、SessionStart が再登録する動作(行は、Running の先頭に移動する)は、変更しない。
- **ターミナルのシェルから実行した `claude -p` は、実行している間だけ行になる**: プロセスが制御端末を持ち、`claude agents` の一覧の `kind` でも、
  対話のセッションと判別できない(§7-9)。対応ターミナルでは、この扱いは、この決定の前から同じである。
- **終了の検出**: reconcile が、`claude agents` の一覧にあって、tty を持ち、どの対応ターミナルの走査にも一致しないセッションを `process:` で送る。
  一覧から無くなったセッションは、既存の prune が削除する。pid の生存の監視などの、新しい仕組みは追加しない。
- **走査が不完全な回の扱い**: どの走査にも一致しないセッションを、更新専用として送る(走査の取りこぼしを、対応ターミナル以外のセッションと区別できないため、
  エントリを作成しない。登録済みのエントリの `last_seen` は更新するので、不完全な回が続いても、生きているエントリは stale で削除されない。`pid` が不明のエントリを除く — daemon の起動の後は、
  target が一致する report または reconcile を受け取るまで、pid で突き合わせられない)。
  更新専用のセッションには、登録済みのセッションと同じ規則(status、unreviewed、`message`)を適用するので、不完全な回が続く間も、
  hook を取りこぼした waiting を拾える。
  1 つのターミナルの走査の失敗(権限の拒否を含む)は、ほかのターミナルの走査の結果の送信を止めない。走査が不完全な回が続く間も、
  登録済みのエントリの更新は続く。その間に止まるのは、prune と、reconcile による新しい `process:` のセッションの登録である
  (hook の report による登録は続く。SessionEnd を受け取らずに終了したセッションのエントリは、走査が完全な回、または stale まで残る)。
- **1 つのセッションを 2 つの target で登録しない**(§3.6「pid による統合」): hook は環境変数で、reconcile はターミナルの走査で target を導出するので、
  同じプロセスに、異なる target を導出する場合がある(環境変数の相続、環境変数の上書き、走査が不完全な回の後など)。
  **エントリの target を決めるのは、走査が完全な回の reconcile だけにする**。hook の report は、target が未登録でも、pid が同じエントリがあれば、
  そのエントリに適用して、target を変更しない。走査は、そのプロセスの tty を持つターミナルを実際に確認するので、環境変数より強い根拠である。
  hook にも target を変更させると、hook と reconcile が異なる target を導出するセッションで、hook のたびと照合のたびに、target が往復する。
  reconcile は、target が登録済みのセッションを先に適用してから、残りのセッションで付け替えを判定する(1 回の reconcile の結果が、
  セッションの並びの順に依存しないようにするため)。daemon は、target の prefix を見分けない(付け替えは、target の文字列の一致と pid だけで判定する)。
- **pid を `state.json` に保存しない理由**: daemon が停止している間(マシンの再起動を含む)に、プロセスが終了して、pid が別のプロセスに再利用される場合がある。
  保存した pid を根拠にすると、終了したセッションのエントリに、別のセッションの内容を適用する。起動の直後は、target だけで突き合わせる。
- **pid の再利用**: SessionEnd を受け取らずに終了したプロセスの pid が、次の照合(§9 の周期)までの間に、別の `claude` のプロセスに再利用された場合、
  新しいセッションの report は、前のエントリに適用される(SessionStart が、状態と未確認を初期化する。`created_at` と `task` は、次の上書きまで前の値が残る)。
  この間隔での再利用は、受け入れる。
- **daemon の起動の直後の二重の登録**: `pid` が不明の間は、hook が導出した target が、登録済みのエントリの target と異なると、
  同じセッションのエントリを、もう 1 つ作成する(未確認と通知を伴う場合がある)。次の完全な回の reconcile の prune が、走査に無い側を削除する。
  この間隔での二重の登録は、受け入れる(保存した pid を根拠にする場合の誤りより、影響が小さい)。
- **バージョンが異なる daemon にアタッチしない**(§4.5「daemon のライフサイクル管理」): `pid`、`update_only`、`rekey` は、アプリ、CLI、daemon の
  3 つが同じバージョンであることを前提にしている。アプリを更新した後に、更新の前の daemon が残っていると、更新専用のセッションからエントリを作成するなど、
  この前提が成立しない。アプリが、アタッチの時点で daemon のバージョンを確認して、異なる場合は同梱の daemon に入れ替える。
  入れ替えを、1 回の起動につき 1 回にして、アプリが spawn した daemon を対象にしないのは、バンドルのバージョンと同梱の daemon のバージョンが
  一致しない構成でも、終了と起動を繰り返さないためである。古い daemon の停止は、Quit と同じ `shutdown` の要求で依頼する(シグナルは送らない)。
  待ち時間の中で停止しなかった入れ替えを保留にして、後のアタッチで停止を確認した時点で spawn するのは、停止が待ち時間より遅い daemon の後に、
  アプリを起動し直すまで daemon が無い状態が続かないようにするためである(既存の spawn は、最初の接続の失敗のときだけ実行する)。
  保留の間に、応答する daemon に `shutdown` をもう一度送らないのは、終了と起動を繰り返さないための上限(1 回の起動につき 1 回)を維持するためである。
- **付け替えの対応は、最新の付け替え先を終端にする**(§4.5「デスクトップ通知」): 走査の結果によって、付け替えは元の target に戻る場合がある
  (`ghostty:<tty>` → `process:<pid>` → `ghostty:<tty>`。§3.6)。対応を追加するだけにすると、対応が循環し、読み替えの結果が、エントリの現在の target にならない。
  付け替え先を古い target とする対応を先に破棄すると、エントリの以前の target は、どれも現在の target に読み替えられる。
- **最初の照合の通知**: 対応ターミナル以外で既に実行中のセッションは、この決定の実装を含むバージョンに更新した後の、最初の reconcile で、
  新しく見つかったセッションとして登録される。idle または waiting のセッションは、未確認になり、通知が 1 回発生する(§3.5 の既存の規則。変更しない)。
- **SSH の接続先のセッションは、対象外のままである**: 接続先の hook は、このマシンの daemon の socket に報告を送れない(§1「非スコープ」)。
- **決定(Ghostty)**: Ghostty 1.4.0 以上を、3 つ目の対応ターミナルにする。target は `ghostty:<tty パス>` である(§2・§4.3・§7-8)。
- **理由**: Ghostty 1.4.0 の AppleScript の `terminal` には `tty` があり(§7-8)、「中からセッションを特定できる値と、外からそのセッションに移動できる手段」の組
  (§8.47 の条件)が成立する。鍵は、Terminal.app と同じ tty なので、祖先 walk と、tty の正規化を、そのまま使用できる。
  最小のバージョンを 1.4.0 にするのは、`tty` があることを確認したバージョンが 1.4.0 で、`v1.3.0` と `v1.3.1` の AppleScript の `terminal` には、`tty` が無いからである(§7-8)。
  1.4.0 未満は、`process:` として追跡する。
- **ターミナルモジュールは、モジュールごとの実装のままにする**(§8.2 と §8.47 の「3 例目の実物を見てから」の判断): 3 つのモジュールで共通なのは、
  関数の形(focus / focused / probe / <ターミナル>_targets / open_resume_window)だけで、中身は、鍵の種類(UUID と tty)、
  走査する構造(セッション、タブ、端末)、コマンドを入力する方法が、モジュールごとに異なる。共通の型を導入しても、モジュールの中の記述は減らず、
  振り分けの入口(prefix → モジュール)は 1 箇所のままである。ターミナルの知識を含まない純関数(tty の正規化など)は、共有する。
  アプリが持つ、ターミナルのバンドル ID と Ghostty の最小のバージョン(Settings の Terminal の判定 — §9)と、report が持つ環境変数の判定(§4.1)は、
  AppleScript と ID の形式の知識ではないので、ターミナルモジュールの外に置く。
- **固有の用語を使用するスクリプトの前に、起動中であることを別のスクリプトで確認する**(§4.3「共通規則」): 対応ターミナルが 3 つになり、
  インストールされていない対応ターミナルがある構成が通常になる。アプリの固有の用語を使用するスクリプトと、バンドル ID でアプリを指定するスクリプトは、
  そのアプリがインストールされていない Mac では、実行の前にエラーになる(§7-10)。reconcile は、エラーになった走査を不完全な走査として扱うので、
  1 つのスクリプトのままでは、その Mac で prune が止まり、終了したセッションの行が残る。iterm2 にも同じ規則を適用する
  (iTerm2 がインストールされていない Mac で、同じ事象が発生するため)。iTerm2 と Ghostty に対する focus、focused、probe、走査で、
  osascript の実行が 1 回増える(iTerm2 の起動中の照会の 1 回の実行は、約 0.05 秒である — 2026-11-21、6 回の計測)。Terminal.app は macOS に含まれるので、対象にしない。
- **apple_terminal の走査と focus は、`id` もタブも読み取れないウィンドウを読み飛ばす**(§4.3・§7-7): Terminal.app は、ターミナルのウィンドウを
  すべて閉じた後も起動している間、そのウィンドウのオブジェクトを保持する場合がある。タブの読み取りがエラーになると、走査のスクリプトの全体がエラーになり、
  reconcile が毎回不完全になる。対応ターミナルが 3 つになり、Terminal.app を、ウィンドウを閉じたまま起動している状態で、ほかのターミナルを使用する構成が
  通常になるので、その状態で prune が止まらないようにする。`id` を読み取れるウィンドウでの失敗は、実在するウィンドウの一時的な失敗として、不完全な走査のままにする
  (生きているセッションを prune しない側に倒す — §3.5)。focus の `activate` と選択の操作を `try` の外に置くのは、iterm2 と同じく、
  操作のエラー(TCC のエラーなど)を「該当なし」と区別して返すためである。
- **入力欄の横に表示される AutoFill のメニューを、アプリの全体で表示しない**(§4.5・§7-11。Edit メニューの AutoFill の項目は対象外である): このアプリには、AutoFill で入力する欄が無い。`Info.plist` の `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac` を true にしても、
  `NSAutoFillHeuristicControllerEnabled` を false にしても、失う機能が無い。`Info.plist` のキーだけでは事象が止まらなかったので、公式の文書に記載の無い `NSAutoFillHeuristicControllerEnabled` を併用する(`NSAutoFillHeuristicControllerEnabled` で事象が止まることは、実機で未確認である — §7-11)。
  検索欄の位置に表示される、内容の無いウィンドウ(§7-11)が、検索の結果を隠す事象への対応である。
- **決定(Resume と Branch のターミナル)**: 開く先を、Settings の `Terminal` で選択する(§4.5・§4.6)。観測による決定と、その記憶
  (`cc.shiibar.lastObservedTerminal`)は廃止する。最初の値は、記憶していた種別から引き継ぐ。
- **理由**: 対応ターミナル以外のセッションを追跡すると、最新のエントリのターミナルが、開く先にできないターミナルである場合が発生し、
  観測では開く先が決まらない。対応ターミナルが 3 つになり、複数を併用する場合に、開く先が直前の操作で変化すると、予測できない。
  §8.47 が設定を採用しなかった理由(設定と、実際に使用しているターミナルの不一致)は、開く先だけを決める設定には当てはまらない
  (セッションを実行しているターミナルの判定は、引き続き、セッションごとに環境変数で実行する)。
- **決定(未確認を下ろす操作)**: 利用者の操作で選択した Running の行の選択が、§9 の時間続いた時点で、未確認を下ろす(§4.5「未確認を下ろす操作」)。
  どのセッションでも同じである。Jump の成功と `Mark all as read` では、すぐに下ろす。選択中の行が未確認になった場合は、自動では下ろさず、
  その行に対する操作(選択が残るクリック、ダブルクリック、Jump ができない行での Enter)から、同じ時間の後に下ろす。会話ペインの操作では下ろさない。
- **理由**: 会話ペインで実行中の会話の返答を読める(§8.65)ので、ターミナルに移動せずに内容を確認する使用が、通常の使用になる。
  Jump の成功だけで下ろす規則では、アプリで返答を読んだ後も点が残り、ジャンプできないセッションでは、`Mark all as read` 以外に下ろす操作が無い。
  ターミナルの種類で規則を分けると、同じ見た目の行で、点が消える操作が異なる。waiting はオレンジで別に示す(§8.65)ので、
  選択で点を下ろしても、操作を待っているセッションは、色で区別できる。
  **選択の時点で下ろさない理由**: ↑ / ↓ で目的の行まで移動する間に通過した行と、誤って選択してすぐに別の行へ移動した行の点が、
  内容を見ていないのに消える。選択が続いた行だけを、確認した行として扱う。
  閉じる前から保持している選択などの、利用者の操作によらない選択は、利用者がその行を選んだ操作ではないので、計測を開始しない。
  ポップオーバーまたはウィンドウを閉じたときに計測を中止するのは、画面を見ていない間に点が消えないようにするためである。
  **会話ペインの操作で下ろさない理由**: スクロールには、利用者の入力によるものと、更新への追従などのアプリが実行するものがあり、
  点が消える場合と消えない場合を、画面から区別できない。下ろす操作を行に対する操作だけにすると、点が消える条件を 1 つの規則で説明できる。
- **決定(グローバルホットキーで開いたときに、行を選択しない)**: ホットキーで開いたときは、一覧にフォーカスを移すだけで、選択を変更しない
  (§4.5「グローバルホットキー」)。選択なしの間は、↑ / ↓ に加えて、一覧にフォーカスがある間の Enter でも、先頭の行を選択する。
- **理由**: 選択は、閉じて開いた後も保持するので、開いたときに先頭の行を選択する動作が発生するのは、選択なしで開いた場合だけである。
  Running は新しいセッションの順(§8.31)なので、先頭の行が、対応の必要な行とは限らない。
  行を選択するのは利用者の操作だけである、という規則(§8.49)に例外が無くなり、「利用者が選択した行は、選択が続くと確認済みになる」を、例外なしで説明できる。
  選択なしで開いた直後に Enter を押した場合に、何も起こらない状態を避けるため、検索欄の Enter と同じ動作を、一覧の Enter にも与える。
- **主ボタンが disabled の Jump である行の、Enter とダブルクリック**: Jump の代わりに、その会話を表示する(1 列では詳細ページ、
  2 列では会話ペインへのフォーカス)。どの行でも、Enter とダブルクリックで、そのセッションの内容に到達できるようにするためである。
  通知のクリックも、ジャンプできないセッションでは、一覧でその行を選択する。
- **disabled のボタンの理由を、下部パネルに文字で表示する**(§4.6「下部パネル」): 理由をツールチップだけで示すと、ポインタをボタンに重ねる操作をしない限り、
  Jump を押せない理由が画面に現れない。ジャンプできないセッションの行は、ほかの Running の行と同じ見た目で、主ボタンだけが押せないので、
  理由を常に表示する。選択したターミナルを使用できないときの Resume と Branch の理由も、同じ位置に表示する。
  表示する位置は、ボタンの行の上の行である。ポップオーバーの幅では、3 つのボタンの横に、どの理由の文言も収まらない(実機で、理由が先頭の 1 文字だけになった)。
  専用の行にすると、どの幅でも全文を表示でき、表示する位置が幅で変化しない。代わりに、理由を表示している間は、パネルが理由の行の分(1 行または 2 行)だけ高くなる。
  カードに印を表示する案は、選択の前に分かるが、理由の全文を表示できず、すべての行に共通の理由(ターミナルを使用できない)には使用できないので、採用しない
- **トレイアイコンの窓の形を、画像の左右の中央に配置する**(menubar-design.html): 窓の左右に同じ幅(3.2pt)の余白を取り、画像の幅を 22.4pt にする。
  右の余白だけを右肩の点の領域にすると、点が無い間は、窓の形が画像の中央から左に寄り、ポップオーバーの矢印が窓の形の中央を指さない。
  点が無い間だけ画像の幅を狭くする案は、点の表示と消去のたびに、隣のアイコンの位置が移動するので採用しない。点を小さくして右の余白をなくす案は、点が目立たなくなるので採用しない
- **hook の実行時間**: すべての report で祖先 walk を実行し、対応ターミナル以外のセッションでも socket に 1 行を書き込むので、hook の 1 回の実行時間が増える。
  この変更の前の値は、中央値で、iTerm2(祖先 walk なし)が 3.1 ms、Terminal.app(祖先 walk あり)が 3.7 ms、対応ターミナル以外(report を破棄)が 3.0 ms だった
  (2026-11-21、条件ごとに 60 回の計測)。変更の後の値(§7-9)は、どの条件も、この値の 2 倍より小さく、100 ms より小さい。祖先 walk による増加は、約 0.6 ms である
- **この決定が変更する仕様**: §8.11(飛べないセッションを追跡しない。フォールバック target を作らない)/ §8.47 の「Resume のターミナルは観測追随」と、
  「対応外を drop する規則」/ §8.48 の「disabled が残るのは、live だが Agents 一覧に一致が無い行だけ」(ジャンプできないセッションの Running の行にも、
  disabled の Jump を表示する。History に残る live の行の表示は、daemon にエントリが無い場合の表示として残る)/ §3.2 の「focus した = seen」
  (利用者が選択した行の選択が続いた場合も seen を送る)/ グローバルホットキーで開いたときの、選択なしの間の先頭の行の選択(行を選択しない)/ reconcile が、TCC エラーのときに何も送らない動作(送ってから exit 3 にする)/
  別プロセスの子のセッションの report が、親のエントリを上書きする動作(§7-3。入れ子のセッションの report として無視する)/
  §8.49 の「disabled の Jump の理由は、ボタンのツールチップで示す」(下部パネルの、ボタンの行の上の行にも表示する)。
  §8.2 の「抽象化レイヤーを作らない」と、§3.4 の遷移の表の各行は、変更しない。
- **再検討の条件**: 別プロセスで起動される子のセッションが、`process:` の別の行と通知になり、利用の妨げになったとき(§7-9)/
  入れ子のセッションの規則が、必要な report を無視していると判明したとき(セッションの中での切り替えの `source` — §7-9)/
  ターミナルのシェルから実行した `claude -p` の行と通知が、利用の妨げになったとき / `/clear` の後も、行の位置と選択を維持する必要が生じたとき
  (SessionEnd の `reason` を report で運び、`clear` では削除しない規則を検討する)/
  エディタのターミナルのセッションの通知を、ターミナルの種類ごとに止める必要が生じたとき / 内容を読んでいない行の点が、選択が §9 の時間続いたことで消え、
  確認の漏れの原因になったとき / Ghostty の tty の再利用による誤ジャンプが問題になったとき(§8.47 の Terminal.app と同じ安全弁を検討する)/
  ターミナルを持たないセッションの追跡が必要になったとき / ウィンドウを閉じてから行が消えるまでの時間(SessionEnd の hook までの約 3.5〜5.5 秒 — §7-12)と、
  その間に行が `process:<pid>` の行になることが、利用の妨げになったとき / 4 つ目のターミナルに対応するとき(関数の形の共通化を、その時点の実物で判断する)/
  `NSAutoFillHeuristicControllerEnabled` を false にした後も、検索欄の位置に、アプリが作成していないウィンドウが表示されると判明したとき(§7-11。ウィンドウの種類を特定して、対応を検討する。この条件は、§8.68 の再検討の条件に置き換えた)/
  §7-9 の「既知の制限」のいずれかが、利用の妨げになったとき(iTerm2 のタブの中の、独自の端末を持つプロセスから起動したセッションでは、
  target が一致するエントリの pid が report の pid と異なり、report の pid を持つエントリが別にある場合に、pid の一致を優先する規則を検討する)。
### 8.67 対話でない方法で起動したセッションを、対象外にする(M57)

- **決定**: `claude -p` で起動したセッション(`entrypoint` が `sdk-cli`)は、追跡せず、会話の一覧にも表示しない。hook は report を送らず(§4.1)、
  reconcile は pid を送らず(§3.5)、索引は transcript を会話として登録しない(§4.6「索引の内容」)。Running、History、検索、`conversations` の CLI のどれにも現れない。
- **理由**: `claude -p` のセッションは、スクリプトや別のセッションが起動する実行で、このアプリの操作の対象にならない。移動する先のタブが無いので Jump はできず、
  通知と状態の表示は、起動した側のセッションの行が担う。一方で、会話の一覧では、スクリプトが繰り返し実行すると、件数の多くを占める場合があり、
  同じ依頼文の行が並んで、対話の会話を探す妨げになる。Recent は先頭の件数だけを表示する(§9)ので、対話の会話が表示の範囲の外に出る。
- **Running も対象外にする理由**: 変更の前は、別のセッションから起動された `claude -p` は Running に表示されず(入れ子のセッションの規則 — §8.66)、
  ターミナルで直接実行した `claude -p` は、実行中だけ Running に表示された。History だけを対象外にすると、実行中は表示され、終了するとどこにも残らない動作になる。
  起動の方法が同じセッションを、場所によらず同じ扱いにする。
- **History に、実行中の会話が表示されていた事象**: 別のセッションから起動された `claude -p` の会話は、daemon にエントリが無く、transcript はあるので、
  プロセスが動作している間、History に `· running` の印で表示されていた。`claude -p` で開始した会話では、この表示は発生しなくなる
  (対話の会話を `claude -p --resume` で続けている間は、その会話が一覧にあり、プロセスは追跡しないので、同じ表示になる場合がある — §7-13 の未検証の点)。
- **判別に使用する値を `sdk-cli` だけにする理由**: 実機で確認できた値だけを対象にする(§7-13)。値が不明の会話を隠すと、表示されない理由が画面から分からない。
  対象外にする値が増えた場合は、表示されている会話から気付いて追加できる。
- **transcript の判定を「`entrypoint` を持つ行のすべて」にする理由**: `claude -p` で開始した会話を、対話で再開して発話を送った場合は、利用者が操作している会話なので、表示する。
  この場合、同じ transcript に `cli` の行が追記される(§7-13)ので、`claude -p` の発話を含む会話の全体を表示する。再開しただけで、発話を送っていない会話は、表示しない。
- **reconcile で `~/.claude/sessions/<pid>.json` を読み取る理由**: `claude agents --json` は、`claude -p` のプロセスを `kind` が `interactive` のセッションとして返し、
  起動の方法を示す項目を持たない(§7-13)。除外しないと、hook が送らなかったセッションを、reconcile が登録する。
- **入れ子のセッションの規則(§8.66)との関係**: `claude -p` の report は hook が送らないので、規則の主な対象は無くなる。規則は、hook が drop しない子のプロセスのために残す。
- **この決定で解除されるスターと Archive**: 対話でない方法で起動した会話に付けたスターと Archive は、その会話が一覧から無くなった時点で、解除される(§4.6 の、一覧に無い会話の整理)。
- **棄却した案**: (1) 現在のまま(History にだけ表示する): 実行中の会話が History に表示され、一覧の件数を占める。
  (2) 表示と非表示を切り替える: 行に `· non-interactive` の印を付け、既定では表示せず、検索の行の下の Filter の行(選択肢は `Hide` / `Show` / `Only`)で切り替え、
  表示する場合は、実行中の会話を Running に 1 つの行として表示する(通知、未確認、メニューバーのアイコンの状態には含めず、主ボタンは disabled の Jump にする)。
  daemon が、子のセッションを、起動した側とは別のエントリとして追跡する必要がある。表示する場面が確認できていないので、採用しない。
- **再検討の条件**: `claude -p` の会話を、アプリで読む、または Resume する必要が生じたとき(棄却した案の (2) を検討する)/ Agent SDK から起動したセッションなど、
  `sdk-cli` 以外の値を持つ、対話でないセッションが、一覧に表示されると判明したとき(§7-13 の未検証の点)。

### 8.68 アプリが作成していないウィンドウの記録を削除する

- **決定**: アプリが作成していないウィンドウを os_log に記録する処理(§8.65)を削除する。入力欄の横に表示される AutoFill のメニューを表示しないための 2 つの設定(§4.5)は残す。
- **理由**: この記録は、検索欄の位置に表示される、内容の無いウィンドウの種類を特定するために追加した。記録によって、ウィンドウのクラスの名前(`SPRoundedWindow`)が分かり、
  AutoFill の推定を無効にする設定で、事象は発生しなくなった(§7-11)。調査が完了した後は、表示のたびにウィンドウの一覧を取得する処理と、そのテストを維持する理由が無い。
  `NSAutoFillHeuristicControllerEnabled` は、公式の文書に記載の無い設定なので、macOS の更新で動作が変わる可能性がある。
- **再検討の条件**: macOS の更新などで、アプリが作成していないウィンドウが、再度表示されると判明したとき(§8.65 と同じ記録を追加して、ウィンドウの種類を特定する)。
- **この決定が変更する過去の決定**: §8.65 の「アプリが作成していないウィンドウの記録」/ §8.66 の再検討の条件のうち、`NSAutoFillHeuristicControllerEnabled` を false にした後もウィンドウが表示される場合の条件
  (この決定の再検討の条件に置き換える)。

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
| バージョンが異なる daemon の停止を待つ時間 | 3 秒(`shutdown` の送信から。停止したかどうかを 0.1 秒の間隔で確認する。停止しなければ、spawn せずに入れ替えを保留にする — §4.5「daemon のライフサイクル管理」) | 固定 |
| report の祖先 walk 上限      | 10 段(上限まで、制御端末を持つプロセスが見つからなければ、report を drop する。SessionEnd だけは、`target` を持たない report として送る。§4.1) | 固定 |
| Ghostty の最小のバージョン   | 1.4.0(AppleScript の `terminal` に `tty` があることを確認したバージョン。`v1.3.1` には無い。比較は、最初の `-` または `+` より前の部分で行う。これ未満の Ghostty のセッションは `process:` になり、Resume / Branch の開く先にできない。§4.1・§4.3・§7-8) | 固定 |
| 対応ターミナルのバンドル ID  | iTerm2 = `com.googlecode.iterm2` / Terminal = `com.apple.Terminal` / Ghostty = `com.mitchellh.ghostty`(Settings の Terminal の、インストールの判定に使用する。§4.5) | 固定 |
| Resume / Branch のターミナル | UserDefaults の `cc.shiibar.resumeTerminal`(`iterm2` / `apple-terminal` / `ghostty`)。最初の値の決め方は §4.5「Settings ウィンドウ」の Terminal | Settings ウィンドウ |
| last_assistant_message の切り詰め | 先頭 200 文字   | 固定                     |
| Refresh の結果の一時表示     | 2 秒(`✓ Refresh done` / `Refresh failed`。§4.6) | 固定 |
| Refresh のアイコンの回転     | 時計回りに 1 秒で 1 回転(Refresh の実行中。等速。「視差効果を減らす」が ON の間は回転しない。§4.5「見出し行」) | 固定 |
| 一覧の行の working スピナーの周期 | 2 秒(グリフ循環 `·✢✳✶✻✽`・コサインイージング。時刻 t 秒のグリフの番号は `round((1 − cos(2πt / 2)) / 2 × 5)` で、グリフはこの値が変化する時刻に切り替わる) | 固定(本家 TUI の実測値) |
| ポップオーバーの大きさ       | 幅 420pt(文字の大きさ 13 のとき。比率で連動する — §4.5「文字の大きさ」)。高さは初回 640pt・最小 300pt・最大はディスプレイの可視領域に収まる高さ。記憶した高さが最大を超えるときは、最大の高さで表示する(記憶した値は変更しない) | 高さだけリサイズ・記憶 |
| ポップオーバーの下端のドラッグ領域 | 高さ 8pt(カーソルは上下リサイズの形) | 固定 |
| Running の行が消えた後の 2 回目の再取得 | 2 秒後 | 固定 |
| 契機 1 の後の、会話ペインの再読み込み | 2 秒後(契機 1 の再読み込みの完了から。§4.6「会話ペインの再読み込み」) | 固定 |
| Recent に表示する行の上限    | 100 行(Running と Starred の区画には適用しない。Archive の一覧の行にも、同じ上限を適用する — §4.6) | 固定 |
| 見出しの帯                   | 高さ 30pt(上端と下端の 1pt の線を含む。文字の大きさ 13 のとき。線を除いて、比率で連動する)。帯の上と下の間隔は 8pt(文字の大きさに連動しない。一覧の最初の帯は、上の間隔を持たない。§4.5「一覧は 3 つの区画」) | 高さだけ文字の大きさに連動 |
| 区画の見出しの Running の印  | 直径 7pt の点(文字の大きさ 13 のとき。比率で連動する)。色は、waiting の行があればオレンジ、無くて未確認の行があればアクセントカラー(§4.5「区画の開閉」) | 文字の大きさに連動 |
| 状態の色                     | waiting = `systemOrange`(一覧の行の状態記号、Running の印、トレイアイコンの点)。未確認 = `controlAccentColor`(一覧の行の点、Running の印、トレイアイコンの点)。§3.1 | システムの色に従う |
| アプリアイコンの点の色       | `#0A84FF`(既定のアクセントカラーに近い青の固定値。明色ハローは白の不透明度 0.9)。§4.5「アプリアイコン」 | 固定 |
| 行のドラッグの開始           | マウスのボタンを押した位置から 4pt 以上の移動(文字の大きさに連動しない。§4.5「行のドラッグ」) | 固定 |
| ドラッグ中の表示             | ポインタに追従する行の画像は不透明度 0.92、元の行は不透明度 0.35、挿入位置にならない行は不透明度 0.4 | 固定 |
| ドラッグできない理由の表示   | 2 秒(§4.5「行のドラッグ」の「ドラッグできない行」) | 固定 |
| 検索欄の高さ                 | 28pt(文字の大きさ 13 のとき。比率で連動する。§4.5「文字の大きさ」) | 文字の大きさに連動 |
| ホットキーで開いたウィンドウの、一覧へのフォーカスの期限 | ウィンドウを開いてから 1 秒(この時間の中で key になった場合だけ、一覧にフォーカスを移す。§4.5「グローバルホットキー」。通知のクリックで開いたウィンドウの、行の選択にも使用する — この時間の中で key にならなかった場合は、時間が経過した時点で選択する。§4.5「通知のクリック」) | 固定 |
| ボタンを離したイベントを受信しない場合の、ドラッグの取り消し | ボタンが離れた状態が 0.25 秒続いたとき(§4.5「行のドラッグ」の「取り消し」) | 固定 |
| ドラッグ中の自動スクロール   | 一覧の上端と下端から 40pt 以内(文字の大きさ 13 のとき。比率で連動する)。速さは、端で 1200pt/秒、範囲の内側の端で 120pt/秒(間は直線で変化する。速さは文字の大きさに連動しない)。ポインタが上端より上、または下端より下にある間は 1200pt/秒 | 範囲だけ文字の大きさに連動 |
| ポップオーバーの高さを初回の高さに固定する範囲 | 初回の高さの前後 12pt 以内(ドラッグ中だけ) | 固定 |
| ウィンドウの大きさ           | 初回 420×640pt・最小 360×300pt。縦横リサイズ可・位置と大きさを記憶 | リサイズ |
| 2 列になる幅                 | 600pt 以上(一覧の列の最小の幅 280pt + 右の列の最小の幅 320pt。未満は 1 列。§4.5) | 固定 |
| 一覧の列の幅(2 列のとき)   | 既定 420pt(文字の大きさ 13 のとき。比率で連動する)。最小 280pt、最大はウィンドウの幅から右の列の最小の幅を引いた幅。ウィンドウの幅を変更しても変化しない(右の列の最小の幅を確保できない場合を除く。§4.5) | 列の境界のドラッグ・記憶(ダブルクリックで既定に戻す) |
| 右の列の最小の幅(2 列のとき) | 320pt(列の境界の線の 1pt を含む) | 固定 |
| 行のタイトルと最後の発話の間隔 | 4pt(文字の大きさ 13 のとき。比率で連動する。ラベルとタイトルの間隔は 1pt) | 文字の大きさに連動 |
| 行の記号と時間の列の幅       | Running の行と Archive の一覧の行は最小 28pt、通常の一覧の History の行は最小 44pt(記号の枠 20pt が 2 つと、その間隔 4pt。文字の大きさ 13 のとき。間隔を除いて、比率で連動する。経過時間が収まらない行は広げる — §4.5)。記号の枠と状態記号は 20pt、スターと三点リーダーは 16pt(同じく連動する) | 文字の大きさに連動 |
| 列の境界のドラッグ領域       | 幅 8pt(境界の線の中心から左右 4pt ずつ。カーソルは左右リサイズの形) | 固定 |
| ページの切り替えのスライド   | 0.22 秒(ease-in-out) | 固定                     |
| 経過時間の再取得             | 60 秒(ポップオーバーまたはウィンドウの表示中のみ) | 固定 |
| wait の既定タイムアウト      | なし(無限待ち)       | `--timeout`              |
| 会話ペインのミニマップ      | 幅 20pt・本文はミニマップ手前 8pt で折り返す(挙動は §4.6) | 固定 |
| 選択で未確認を下ろすまでの時間 | 1 秒(利用者の操作で Running の行を選択した時点から計測する。§4.5「未確認を下ろす操作」) | 固定 |
| 発言コピーの反応             | 1 秒(アイコンをチェックマークに替え、アイコンの左に `Copied` を表示する時間。§4.6「発言ごとのコピー」) | 固定 |
| Settings のタブの行の寸法    | 行の余白は上下 6pt・左右 12pt、ボタンの間隔 4pt。ボタンは、最小の幅 72pt、余白が上下 6pt・左右 8pt、アイコン 18pt、アイコンと名前の間隔 3pt、名前 11pt、選択中の地の角の半径 7pt。§4.5「Settings ウィンドウ」 | 固定 |
| Settings ウィンドウの寸法    | ウィンドウの幅 600pt(どのタブでも同じ)。内容の余白は上 16pt・左右 24pt・下 20pt。枠と枠の間隔 14pt。見出しと枠の間隔 6pt、見出しの左の字下げ 4pt。枠の角の半径 10pt。行の余白は上下 9pt・左右 14pt、行の内容の最小の高さ 22pt、左と右の列の間隔 12pt、ラベルと説明の間隔 2pt。右の列の幅 240pt(中の間隔 8pt)。§4.5「Settings ウィンドウ」 | 固定 |
| Settings のエラーと案内の文字の色 | ライト `#A0390A`、ダーク `#F08A5D`(§4.5「Settings ウィンドウ」) | 固定 |
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
  shiibar-cc の main への変更は、プルリクエストと CI の成功を必須にする(CI が失敗する変更を、main に入れないため)。
  Dependabot(alerts + security updates)と secret scanning + push protection も有効。
  設定の一覧と運用(PAT の期限対応を含む)は DEVELOPMENT.md「リポジトリ設定と Secrets の運用」
