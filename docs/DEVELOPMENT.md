# 開発メモ

日々の開発・ドッグフーディングで使う手順のメモ。仕様の正は [DESIGN.md](DESIGN.md)、
メニューバーの見た目の正は [menubar-design.html](menubar-design.html)。

## レビュー・検証体制

マイルストーンごとに 3 段階で受け入れる:

1. **実装エージェント**: 実装 + 自身のテスト(指示書 `docs/tasks/Mx.md` に従う)
2. **spec 突き合わせレビュー**: 遷移表(DESIGN.md §3.4)・決定の記録(§8)・プロトコル契約(§4.2)との整合を確認
3. **独立検証エージェント**(実装者とは別に起動): 実装知識に引きずられないよう、
   **先に spec と指示書だけから期待動作を導出**し、ブラックボックスで検証する
   (daemon を実際に起動して socket に生 NDJSON を打つ、再起動復元、exit code など)。
   実装コードを読むのは最後(テストの網羅漏れ探しのみ)

## セットアップ

- **Rust**: `rust-toolchain.toml` でバージョン固定(rustup が自動でダウンロードする)。mise は使わない
- **Swift**: ビルド(`swift build`)は Command Line Tools のみで可(いずれも `app/` で実行)。
  **`swift test` には Xcode 本体が必要**
  (CLT のみの環境では `could not determine XCTest paths` の警告が出るが、ビルドには無害)。
  Xcode を入れたら `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` で切り替える

## よく使うコマンド

```sh
cargo build
cargo test

# daemon 単体をログを見ながら動かす(daemon まわりを触るときの手動運用)
SHIIBAR_CC_LOG=debug cargo run -p shiibar-ccd -- --foreground

# 別ターミナルからイベント観測
cargo run -p shiibar-cc -- watch

# テスト・実験用に状態ディレクトリを分離(本物の ~/.local/state/shiibar-cc を汚さない)
SHIIBAR_CC_STATE_DIR=$(mktemp -d) cargo run -p shiibar-ccd -- --foreground
```

## hooks の検証

- `hooks/settings-snippet.json` は `$HOME/.local/bin/report.sh` を指す(install.sh 導入後の配置。M2)。
  それ以前に実機で試す場合は、コマンドをリポジトリ内 `hooks/report.sh` の絶対パスに読み替え、
  `shiibar-cc` は `cargo build` 後に `target/debug/` を PATH に入れる

- 実ペイロードの採取: hooks を設定した実セッションで対象イベントを発生させ、受信した実 hook JSON を `fixtures/` に保存する
- 偽装再生: `echo '<hook JSON>' | shiibar-cc report <event>`(実 Claude Code なしで daemon の遷移を再現できる)
- 要検証リスト(DESIGN.md §7-3): `elicitation_*` の実際の意味 / `PostToolUseFailure` の実発火

## macOS 権限まわり

- **M2(focus 初回実行時)**: 「オートメーション(iTerm2 の制御)」の許可ダイアログが出るので許可する。
  誤って拒否した場合: システム設定 → プライバシーとセキュリティ → オートメーション から付け直す。
  ターミナルから実行する CLI と、メニューバーアプリからの実行では**許可が別々に**必要
- **M4(アプリ初回起動時)**: 通知の許可ダイアログ。ad-hoc 署名は再ビルドで権限がリセットされることがある
  (install.sh で安定した署名 ID を使う。DESIGN.md §4.5)
- 「通知が来ない」等の切り分けは `shiibar-cc doctor`(M2 で実装)

## M2 実機スモーク(osascript 権限が要るため人間が行う)

`scripts/install.sh` でバイナリ配置後、素の iTerm2 タブで試すこと
(tmux は非スコープ。§8.1):

> **フォルダを移動したら `cargo clean` を1回**。`env!("CARGO_MANIFEST_DIR")` がビルド時に
> 絶対パスを焼き込むため、リポジトリを移動するとテスト(fixtures 読み込み)が旧パスを見て
> 失敗する。クリーンビルドで直る(2026-07-04 の shiibar → shiibar-cc 移動で遭遇)。

```sh
SHIIBAR_CC_LOG=debug shiibar-ccd --foreground      # 1 タブで起動しておく
shiibar-cc doctor                            # 全項目 [ok]。初回 osascript でオートメーション許可を求められたら許可
shiibar-cc list                              # このセッションが idle で見えるか
shiibar-cc wait . --status idle && say done  # このタブで Claude のターンを回して完了を待つ
shiibar-cc focus <list で見えた target>      # 別タブから該当タブが前面に来るか
shiibar-cc focused                           # 前面タブの target が出るか
shiibar-cc focus w9t9p9:garbage ; echo $?    # 該当なしで exit 2
```

- **既知の注意**: osascript 呼び出しにタイムアウトがない。初回 TCC ダイアログ待ちや iTerm2 の応答遅延で
  focus/focused が一時的にハングし得る(検証中に約 2 分の事例が 1 回、再現性なし)。ハングしたら Ctrl-C でよい
- **AppleScript の制約(2026-07-04 実機で確認)**: iTerm2 の `id of session`(UUID)・`index of window` は
  取れるが `index of tab` は取れない(`-1728`)。focused は UUID のみ返す実装にしてある。
  この種の「実 iTerm2 と AppleScript の相性」は fake runner の単体テストでは捕まらないので、
  iterm モジュールを変えたら必ず実機で focus / focused を叩くこと

## ドッグフーディング運用

- 日常のドッグフーディングはインストール済みの `.app` で行う(`scripts/install.sh` で
  `~/Applications/ShiibarCC.app` を配置。Login Item として登録され、daemon の起動・アタッチ・
  停止はアプリが管理する。DESIGN.md §4.5 / §8.8。launchd には入れない、§8.8)
- コード変更の反映は `scripts/dev-reload.sh`(下記「リリース・インストール」参照)
- daemon 単体をログを見ながら動かしたいとき(daemon とアプリの連携をいじるときなど)は
  手動運用に切り替える: アプリを Quit してから iTerm2 の 1 タブで
  `SHIIBAR_CC_LOG=debug shiibar-ccd --foreground` を動かし、アプリは
  `swift run --package-path app ShiibarCcApp` で起動する。アプリは起動時に既存 daemon に
  アタッチするので、手動 daemon と併用しても壊れない。ただしアプリを Quit すると
  daemon も止まる(§8.8)
- 状態ファイルは `~/.local/state/shiibar-cc/`。壊れたら丸ごと消してよい

## リリース・インストール

- `scripts/install.sh`: リリースビルドして `~/Applications/ShiibarCC.app`
  (`SHIIBAR_CC_APP_DIR` で上書き可)を組み立て、安定したローカル署名 ID で署名する
  (再ビルドで通知権限がリセットされないようにするため。DESIGN.md §4.5。ID が無ければ
  `scripts/lib/make-local-signing-identity.sh` で作成する)。`~/.local/bin/`
  (`SHIIBAR_CC_BIN_DIR` で上書き可)には bundle 内バイナリへのシンボリックリンクと
  `report.sh` を配置。最後にアプリを 1 回起動する(Login Item として自己登録。§4.5)。
  `~/.claude/settings.json` への自動マージはしない(既存設定を壊すリスクを避けるため。
  `hooks/settings-snippet.json` の中身を表示するので手で貼るか、jq があれば案内されるコマンドで確認しながらマージする)
- `scripts/uninstall.sh`: 2 段階
  - 引数なし: `.app`(Login Item 登録ごと)と `~/.local/bin/` に置いたシンボリックリンク・
    `report.sh` を削除する。settings.json に `report.sh` への参照が残っていれば手動で外す案内を
    表示するのみ(自動編集はしない)。state dir・署名 ID・TCC・通知許可はそのまま残す
    (入れ直しを前提にした軽い撤去)
  - `--purge`: 上記に加えてフルの撤去を行う。`~/.claude/settings.json` から `report.sh` を指す
    hooks エントリだけを jq で取り除き(他の hooks・設定は保持、書き換え前に
    `settings.json.bak` へバックアップ。ファイルが無ければ何もせず終了し、jq が無い・
    JSON が壊れている場合は自動編集をスキップして手動での案内を表示する)、state dir
    (`SHIIBAR_CC_STATE_DIR` の既定パス)を削除し、`defaults delete cc.shiibar.menubar`・
    ローカル署名 ID(`shiibar-cc-local-signing`、`scripts/lib/signing.sh`)の
    `security delete-certificate`・`tccutil reset AppleEvents cc.shiibar.menubar` を実行する。
    通知許可だけはプログラムから削除できないため、システム設定 → 通知 からの手動削除を案内して終わる
- `scripts/dev-reload.sh`: 日常のホットスワップ。デバッグビルド(cargo + swift)を作り、
  インストール済みアプリを Quit し、daemon が確実に終了するのをスクリプト側で保証してから
  (Quit 経由の shutdown 送信は投げっぱなしでプロセス終了と競合して失われ得るため、
  socket への `{"cmd":"shutdown"}` → SIGTERM → SIGKILL の順に確認する)、bundle 内の
  バイナリを差し替え、install.sh と同じ安定した署名 ID で再署名して(`scripts/lib/signing.sh`。
  ID が keychain に無ければ警告付きで ad-hoc にフォールバック)、アプリを再起動する。
  署名 ID が安定しているので、通知権限はリロードをまたいで維持される(§4.5)。
  アプリ未インストールの環境ではビルドのみ行い、手動運用の手順
  (`shiibar-ccd --foreground` + `swift run`)を表示する
- 動作確認は `shiibar-cc doctor`(daemon 疎通・hooks 設定・PATH・osascript 権限を順に表示)
