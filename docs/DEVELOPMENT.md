# 開発メモ

日々の開発・ドッグフーディングで使う手順のメモ。仕様の正は [DESIGN.md](DESIGN.md)、
メニューバーの見た目の正は [menubar-design.html](menubar-design.html)。

> このメモは実装の進行に合わせて追記する。未実装のものは「(Mx で追記)」と記してある。

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
- **Swift**: Command Line Tools のみでビルド可。Xcode 本体は不要
- **fzf**(任意): `shiibar-cc resume` の選択 UI が快適になる。なければ番号選択

## よく使うコマンド(M1 で追記)

```sh
cargo build
cargo test

# daemon をログ付きフォアグラウンドで起動(開発中の基本形)
SHIIBAR_CC_LOG=debug cargo run -p shiibar-ccd -- --foreground

# 別ターミナルからイベント観測
cargo run -p shiibar-cc -- watch

# テスト・実験用に状態ディレクトリを分離(本物の ~/.local/state/shiibar-cc を汚さない)
SHIIBAR_CC_STATE_DIR=$(mktemp -d) cargo run -p shiibar-ccd -- --foreground
```

## hooks の検証(M1)

- `hooks/settings-snippet.json` は `$HOME/.local/bin/report.sh` を指す(install.sh 導入後の配置。M2)。
  それ以前に実機で試す場合は、コマンドをリポジトリ内 `hooks/report.sh` の絶対パスに読み替え、
  `shiibar-cc` は `cargo build` 後に `target/debug/` を PATH に入れる

- 実ペイロードの採取: hooks を設定した実セッションで動かし、実 hook JSON を `fixtures/` に保存する(手順は M1 実装時に追記)
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
shiibar-cc focus -                           # 直前の前面タブに戻るか
shiibar-cc focus w9t9p9:garbage ; echo $?    # 該当なしで exit 2
```

- **既知の注意**: osascript 呼び出しにタイムアウトがない。初回 TCC ダイアログ待ちや iTerm2 の応答遅延で
  focus/focused が一時的にハングし得る(検証中に約 2 分の事例が 1 回、再現性なし)。ハングしたら Ctrl-C でよい
- **AppleScript の制約(2026-07-04 実機で確認)**: iTerm2 の `id of session`(UUID)・`index of window` は
  取れるが `index of tab` は取れない(`-1728`)。focused は UUID のみ返す実装にしてある。
  この種の「実 iTerm2 と AppleScript の相性」は fake runner の単体テストでは捕まらないので、
  iterm モジュールを変えたら必ず実機で focus / focused を叩くこと

## ドッグフーディング運用(M2〜M3 の期間)

- daemon は launchd に入れない(DESIGN.md §8.8)。iTerm2 の 1 タブで `shiibar-ccd --foreground` を
  動かしておく(ログが見えるので開発中はむしろ都合が良い)
- 状態ファイルは `~/.local/state/shiibar-cc/`。壊れたら丸ごと消してよい
  (`sessions.jsonl` だけは resume 履歴なので、消すと履歴も消える)
- アプリ(M4 以降)は起動時に既存 daemon にアタッチするので、手動 daemon と併用しても壊れない。
  ただしアプリを Quit すると daemon も止まる(仕様)

## リリース・インストール(M2 / M4 で追記)

- `scripts/install.sh`: `cargo build --release` して `shiibar-ccd` / `shiibar-cc` / `hooks/report.sh` を
  `~/.local/bin/`(`SHIIBAR_CC_BIN_DIR` で上書き可)に配置する。M2 段階ではバイナリ配置 + hooks 案内のみで、
  `~/.claude/settings.json` への自動マージはしない(既存設定を壊すリスクを避けるため。
  `hooks/settings-snippet.json` の中身を表示するので手で貼るか、jq があれば案内されるコマンドで確認しながらマージする)。
  `.app` 化・Login Items・CLI シンボリックリンクの `.app` 由来化は M4
- `scripts/uninstall.sh`: `~/.local/bin/` に置いたものを削除し、settings.json から hooks を外す案内を表示する
  (`~/.local/state/shiibar-cc/` は消さない。resume 履歴・ログが要らないなら手動で消す)
- `scripts/dev-reload.sh`: `cargo build`(デバッグビルド)を再実行するだけの薄いラッパー。
  daemon は手動運用(§8.8)なので、動かしている `shiibar-ccd --foreground` は自分で Ctrl-C → 再実行する
- 動作確認は `shiibar-cc doctor`(daemon 疎通・hooks 設定・PATH・osascript 権限を順に表示)
