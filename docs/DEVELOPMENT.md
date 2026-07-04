# 開発メモ

日々の開発・ドッグフーディングで使う手順のメモ。仕様の正は [DESIGN.md](DESIGN.md)、
メニューバーの見た目の正は [menubar-design.html](menubar-design.html)。

> このメモは実装の進行に合わせて追記する。未実装のものは「(Mx で追記)」と記してある。

## レビュー・検証体制

マイルストーンごとに 3 段階で受け入れる:

1. **実装エージェント**: 実装 + 自身のテスト(指示書 `docs/tasks/Mx.md` に従う)
2. **spec 突き合わせレビュー**: 遷移表(DESIGN.md §3.1)・決定の記録(§8)・プロトコル契約(§4.2)との整合を確認
3. **独立検証エージェント**(実装者とは別に起動): 実装知識に引きずられないよう、
   **先に spec と指示書だけから期待動作を導出**し、ブラックボックスで検証する
   (daemon を実際に起動して socket に生 NDJSON を打つ、再起動復元、exit code など)。
   実装コードを読むのは最後(テストの網羅漏れ探しのみ)

## セットアップ

- **Rust**: `rust-toolchain.toml` でバージョン固定(rustup が自動でダウンロードする)。mise は使わない
- **Swift**: Command Line Tools のみでビルド可。Xcode 本体は不要
- **fzf**(任意): `shiibarctl resume` の選択 UI が快適になる。なければ番号選択

## よく使うコマンド(M1 で追記)

```sh
cargo build
cargo test

# daemon をログ付きフォアグラウンドで起動(開発中の基本形)
SHIIBAR_LOG=debug cargo run -p shiibard -- --foreground

# 別ターミナルからイベント観測
cargo run -p shiibarctl -- watch

# テスト・実験用に状態ディレクトリを分離(本物の ~/.local/state/shiibar を汚さない)
SHIIBAR_STATE_DIR=$(mktemp -d) cargo run -p shiibard -- --foreground
```

## hooks の検証(M1)

- `hooks/settings-snippet.json` は `$HOME/.local/bin/report.sh` を指す(install.sh 導入後の配置。M2)。
  それ以前に実機で試す場合は、コマンドをリポジトリ内 `hooks/report.sh` の絶対パスに読み替え、
  `shiibarctl` は `cargo build` 後に `target/debug/` を PATH に入れる

- 実ペイロードの採取: hooks を設定した実セッションで動かし、実 hook JSON を `fixtures/` に保存する(手順は M1 実装時に追記)
- 偽装再生: `echo '<hook JSON>' | shiibarctl report <event>`(実 Claude Code なしで daemon の遷移を再現できる)
- 要検証リスト(DESIGN.md §7-2): `idle_prompt` の発火条件と対象状態 / `elicitation_*` の実際の意味 / `background_tasks` の実ペイロード形式

## macOS 権限まわり

- **M2(focus 初回実行時)**: 「オートメーション(iTerm2 の制御)」の許可ダイアログが出るので許可する。
  誤って拒否した場合: システム設定 → プライバシーとセキュリティ → オートメーション から付け直す。
  ターミナルから実行する CLI と、メニューバーアプリからの実行では**許可が別々に**必要
- **M4(アプリ初回起動時)**: 通知の許可ダイアログ。ad-hoc 署名は再ビルドで権限がリセットされることがある
  (install.sh で安定した署名 ID を使う。DESIGN.md §4.5)
- 「通知が来ない」等の切り分けは `shiibarctl doctor`(M2 で実装)

## ドッグフーディング運用(M2〜M3 の期間)

- daemon は launchd に入れない(DESIGN.md §8.8)。iTerm2 の 1 タブで `shiibard --foreground` を
  動かしておく(ログが見えるので開発中はむしろ都合が良い)
- 状態ファイルは `~/.local/state/shiibar/`。壊れたら丸ごと消してよい
  (`sessions.jsonl` だけは resume 履歴なので、消すと履歴も消える)
- アプリ(M4 以降)は起動時に既存 daemon にアタッチするので、手動 daemon と併用しても壊れない。
  ただしアプリを Quit すると daemon も止まる(仕様)

## リリース・インストール(M2 / M4 で追記)

- `scripts/install.sh` / `uninstall.sh` / `dev-reload.sh` の使い方をここに書く
