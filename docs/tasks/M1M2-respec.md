# M1/M2 再整合(respec)実装指示書: 旧状態モデル → 新状態モデル

> 読む順番: ルートの `CLAUDE.md` → この指示書 → `docs/DESIGN.md`(特に §2 / §3 全部 / §4)。
> 参考: `docs/tasks/M1.md` / `M2.md`(新モデルに更新済み。完成形の定義)。
> 仕様の正はあくまで DESIGN.md。食い違い・曖昧さを見つけたら実装で解決せず、完了報告で指摘すること。

## 背景

M1/M2 は**旧状態モデル**(status 4 値 working / blocked / done / idle、`session:` フォールバック target、
seen = done→idle)で実装・テスト済み。その後 `docs/DESIGN.md` が**新モデル**に再設計された。
このタスクは、コードとテストを新 spec に完全整合させる**移行作業**である。新規機能(reconcile 系)も含む。

## 新モデルの要点(正確な定義は DESIGN.md §2・§3)

1. **status は 3 値**: `working` / `waiting` / `idle`(`Blocked`→`Waiting` 改名、`Done` 廃止。
   前方互換の `Unknown` フォールバックは維持)
2. **`unreviewed` フラグ**(bool)を各エントリに追加(§3.2)。waiting / idle にのみ立つ。
   set / clear は遷移規則で決まる(§3.2・§3.4 の flag 列)。**§3.4 の表がテスト仕様**
3. **`seen` は unreviewed を下ろすだけ**。status は変えない(旧 done→idle は廃止)
4. **Notification(idle_prompt)は完全に無視**(旧: working→blocked)
5. **target は iTerm2 セッションの裸 UUID**(§2)。`shiibar-cc report` は `$ITERM_SESSION_ID` の
   `:` 以降を切り出す。**`$ITERM_SESSION_ID` が無ければ report を drop**(送信せず exit 0)。
   `session:<session_id>` フォールバックは廃止(iterm モジュールの特別扱いも削除)
6. **reconcile**(§3.5・§4.2): daemon に `{"cmd":"reconcile","complete":bool,"sessions":[…]}` を追加。
   CLI に `shiibar-cc reconcile` サブコマンドを追加(`claude agents --json` → status マップ →
   `iterm_targets` で pid→target 導出 → daemon へ送信)。iterm モジュールに `iterm_targets(pids)` を追加

## 変更箇所インベントリ(調査済み)

これは出発点であり網羅保証ではない。最後に `blocked` / `done` / `session:` を全 grep して掃くこと。

### crates/shiibar-cc-proto
- `src/lib.rs:19-28` `Status` enum: `Blocked`→`Waiting`、`Done` 削除、`Unknown`(`#[serde(other)]`)維持
- `src/lib.rs:31-43` `Agent` に `unreviewed: bool` を追加(list / snapshot / status_changed に載る。§4.2)
- `src/lib.rs:127-138` `Request` に `Reconcile { complete, sessions }` を追加 +
  reconcile セッションの payload 型(target / session_id / cwd / status / waiting_for。§4.2)
- `src/extract.rs:46-49` `build_report`: `session:` フォールバック廃止 →
  `$ITERM_SESSION_ID` の `:` 以降を target に。無し/空なら「drop」を表す戻り値(呼び出し元が送信をスキップ)
- `SessionRecord.last_status`(`lib.rs:119-124`): 型はそのまま。ディスク上の旧 `done` 行は
  `Unknown` にデシリアライズされる(許容。移行コードは書かない)

### crates/shiibar-ccd
- `src/transitions.rs` 全面: §3.4 の表(status 列 + flag 列)どおりに書き直し
  - `apply_seen`(`:79-88`): flag を下ろすだけに(status・since 不変)
  - idle_prompt(`:129-136`): 無視に変更(未登録でも登録しない)
  - Stop・background_tasks 空(`:150-172`): → idle + **unreviewed を立てる**
  - Notification(waiting 系・未知・欠落): → waiting + **無条件に立てる**(同値 waiting でも立て直す。§3.2)
  - working への遷移(UserPromptSubmit / PostToolUse の waiting→working / Stop bg 残)と
    SessionStart(非 compact)は flag を**下ろす**
  - 未登録時の登録: Notification(waiting 系)= waiting+flag、Stop 空 = idle+flag、
    UserPromptSubmit / PostToolUse / Stop bg 残 = working(flag 無し)、SessionStart = idle(flag 無し)
  - `set_status`(`:250-258`): message クリア条件を `!= Waiting` に
- `src/state.rs`: `AgentEntry` に `unreviewed: bool`(**`#[serde(default)]`** — 旧 state.json を読めること)。
  `to_wire` / `observable()`(`:45-57`)に unreviewed を追加(flag だけの変化も配信対象。§4.2)。
  旧 status 文字列(`blocked` / `done`)は `Unknown` として読み込まれる — 移行コードは書かず、
  そのまま保持してよい(list では `unknown` 表示。次の reconcile が正しい status に直すか prune する)
- `src/core.rs` + `src/server.rs`: `reconcile` コマンドの適用(§3.5)—
  add(idle / waiting の新発見は flag を立てる。working は立てない)/
  update(claude agents が常に勝つ。waiting へ遷移 = flag 立てる。**既知の idle への遷移では立てない**。
  不変なら flag に触らず last_seen のみ更新。waiting なら message を waiting_for で更新。waiting 以外へ移ったら message クリア)/
  prune(`complete:true` のときのみ。削除は `agent_removed` を配信)。
  状態が変われば state.json 永続化・配信は report と同じ規則
- テスト:
  - `tests/transitions_table.rs`: §3.4 と一対一に再構成。開始状態は(未登録 / idle / working / waiting)×
    unreviewed の有無が意味を持つケース。**status 列と flag 列を独立に assert**
  - `tests/fixtures_replay.rs`: `session:` target 廃止 → 実形式の UUID target で再生
    (fixtures の hook JSON はそのまま、テストハーネスが iterm_session_id を渡す)。Done ステップを新モデルに
  - `tests/restart_persistence.rs`: waiting + unreviewed が復元されること
  - reconcile の結合テスト(add / update / prune / flag / complete:false)を追加
  - `tests/stale_sweep.rs`: 軽微(idle のまま)

### crates/shiibar-cc-client
- `src/iterm.rs`: `session:` 特別扱い(`:97-112` extract_uuid、`:311-318` focus、関連テスト)を削除。
  `extract_uuid` は裸 UUID と `wNtNpN:UUID` の両方を受ける。
  **`iterm_targets(pids)` を新設**: `ps` で pid→tty、AppleScript で全セッションの tty+UUID を列挙して突き合わせ。
  既存の分離パターン(純関数の script builder / output parser + `AppleScriptRunner` 注入)を踏襲し、
  `ps` 実行も注入可能にして純関数部を単体テストする。
  走査の失敗・不完全を戻り値で区別(reconcile が complete:false を送る判断に使う)
- reconcile の gather ロジック(`claude agents --json` のパース、status マップ busy/shell→working、
  waiting→waiting、idle→idle、waitingFor 抽出)は client 側に置く。`claude` 実行部は注入可能に。
  実ペイロード形式は §7-2 に記録済み(`sessionId` / `cwd` / `pid` / `status` / `statusUpdatedAt` / `waitingFor`)
- `tests/wait_integration.rs`: Blocked→Waiting、Done→Idle に書き換え

### crates/shiibar-cc
- `src/wait_cmd.rs:11-19` + `src/main.rs:87,93`: `--status idle|working|waiting`
- `src/list_cmd.rs:56-64`: `waiting` 表示、`done` 削除。テキスト形式は unreviewed のエントリの
  status に `*` を後置する(例: `waiting*`)。`--json` は proto をそのまま(unreviewed が入る)
- `src/main.rs`: `reconcile` サブコマンド追加(+ usage)。exit code は共通規則
  (走査失敗で complete:false を送った場合も、送信できていれば 0)
- `src/report_cmd.rs:46-48`: drop 規則(上記 proto の変更に追従。常に exit 0 は不変)
- `tests/exit_codes.rs` / `tests/report_cli.rs`: 新モデルに書き換え
  (`falls_back_to_session_target_without_iterm_session_id` は「drop して何も送らない」テストに置換)

### 変更不要(確認済み)
- `hooks/report.sh` / `hooks/settings-snippet.json` / `scripts/install.sh`(reconcile は追加バイナリ不要)
- `src/watch_cmd.rs`(raw JSON 転送)/ `src/doctor_cmd.rs` / proto の codec

## 受け入れ条件

- テストは DESIGN.md §3.4 の表と一対一対応(弱めない。実装をテストに合わせるのではなく、表に合わせる)
- reconcile の規則(§3.5)を結合テストで検証(上記テスト項目)
- 旧 state.json(unreviewed 無し・旧 status 文字列)を読んでもクラッシュしない
- `cargo test` 全緑、`cargo clippy --all-targets` 警告ゼロ
- すべてのテストは一時 `SHIIBAR_CC_STATE_DIR`。マシン固有絶対パス禁止。コード・コメント・テスト名は英語のみ

## スコープ外(やらない)

- resume(M3)、メニューバーアプリ・通知(M4)、install.sh の変更
- reconcile の定期ポーリング(§8.10)、PreToolUse 連携(§8.7)
- `docs/` の編集(DESIGN.md §8 はもちろん、他の節も。指摘は完了報告で)
- osascript / `claude` / `ps` を実際に叩く自動テスト(すべて注入で代替)

## 完了報告に含めるもの

- cargo test / clippy の結果要約、変更ファイル一覧
- 仕様が沈黙していて自分で決めた点のリスト(各 1 行)
- 仕様の矛盾・疑問点(DESIGN.md への修正提案として。直接編集はしない)
- 実機スモークの手順(reconcile を含む: 幽霊の掃除・見逃した waiting の復元を確認するコマンド列)
