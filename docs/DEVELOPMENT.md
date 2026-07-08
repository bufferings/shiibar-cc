# 開発メモ

日々の開発・ドッグフーディングで使う手順のメモ。仕様の正は [DESIGN.md](DESIGN.md)、
メニューバーの見た目の正は [menubar-design.html](menubar-design.html)。

## レビュー・検証体制

マイルストーンごとに受け入れる。**順序は固定**で、後の段を先にやらない:

1. **実装エージェント**: 実装 + 自身のテスト(指示書 `docs/tasks/Mx.md` に従う)
2. **spec 突き合わせレビュー**: 遷移表(DESIGN.md §3.4)・決定の記録(§8)・プロトコル契約(§4.2)との整合を確認
3. **独立検証エージェント**(実装者とは別に起動): 実装知識に引きずられないよう、
   **先に spec と指示書だけから期待動作を導出**し、ブラックボックスで検証する
   (daemon を実際に起動して socket に生 NDJSON を打つ、再起動復元、exit code など)。
   実装コードを読むのは最後(テストの網羅漏れ探しのみ)
4. **実機スモーク(所有者)**: dev-reload / dev-install.sh で実機に反映し、目視・実操作で確認する。
   DESIGN.md §6 のとおり、これも完了条件の一部 — 自動テスト緑は完了ではない
5. **push は 4 が終わってから**。push = 公開なので、受け入れが済んでいない変更を公開しない。
   例外は実機で確認するものが無い変更(docs のみ・CI 設定のみ等)だけ

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

## CI

- push / PR ごとに GitHub Actions が回る(`.github/workflows/ci.yml`: macOS ジョブで
  cargo test / clippy(いずれも `--locked`)と swift build / swift test と cask テンプレートの
  `brew style --cask` 検査、Linux ジョブで cargo-deny(設定は `deny.toml`))
- **push 後の結果確認は、必ずコミット SHA で run を特定する**。SHA は**フル(40 桁)が必須** —
  `--commit` に短縮 SHA を渡すとエラーにならず黙って 0 件が返り、「run が無い」と誤診する
  (2026-07-08 実例)。run の登録は push から数秒〜十数秒遅れるので、登録待ちと完了待ちを分ける:

  ```sh
  sha=$(git rev-parse HEAD)   # フル SHA を保証する(手打ちの短縮形を使わない)
  for _ in $(seq 1 20); do    # 登録待ちは最大 5 分(15 秒 × 20)。無限に待たない
    run_id=$(gh run list --commit "$sha" --json databaseId --jq '.[0].databaseId') && [ -n "$run_id" ] && break
    sleep 15
  done
  [ -n "$run_id" ] || { echo "no CI run registered for $sha" >&2; exit 1; }
  gh run watch "$run_id" --exit-status
  ```

  `gh run list --limit 1` で「最新の run」を摑む方法は**使わない**: push 直後は新しい run が
  まだ登録されておらず、直前の push の run を誤って摑む(それを緑と誤報した実例あり。2026-07-07)

## リポジトリ設定と Secrets の運用

リポジトリを clone しても見えない GitHub 側の設定の記録(方針は DESIGN.md §10)。

- **ruleset `protect-main`**(shiibar-cc / homebrew-tap の両方): main への force-push と
  ブランチ削除を禁止。バイパスなし(管理者にも適用)。本当に必要になったら
  Settings → Rules で一時的に無効化する
- **ruleset `protect-release-tags`**(shiibar-cc): `v*` タグの削除・付け替えを禁止
  (DESIGN.md §8.28「公開後のタグ再利用禁止」の強制)。リリースに失敗したらタグを直すのではなく
  次のパッチ番号で切り直す
- **Dependabot**(shiibar-cc): alerts + security updates が有効。依存の脆弱性が公表されると
  Security タブとメールで通知され、修正版があれば bump PR が自動で立つ(平時は無音)。
  PR は CI(cargo test / clippy / cargo-deny)の緑を確認してマージする。
  homebrew-tap は依存が無いので対象外。CI の cargo-deny は push 時にしか走らないので、
  リリース間の無活動期間は Dependabot の常時監視が補完する
- **secret scanning + push protection**: 両リポジトリで有効(public リポジトリの既定)。
  既知パターンのトークンは push 時にブロックされる。ただし `.p12` などのバイナリや任意の
  パスワードは検出できない — 鍵ファイルはリポジトリの外で扱い、使い終わったら消す運用が第一の防御
- **tap リポジトリ(homebrew-tap)は最低 1 コミット必要**: 完全に空(ブランチなし)だと
  bump-cask の checkout が `couldn't find remote ref refs/heads/main` で落ちる
  (v0.1.0 publish 時に実例 — 初期 README コミットを作って再実行で解消。2026-07-09)
- **利用者側の tap trust**: 現行の Homebrew は非公式 tap の信頼要求が**既定で有効**
  (`HOMEBREW_REQUIRE_TAP_TRUST` の default = true)で、未信頼の tap の cask はロード時点で
  操作ごと拒否される — ただし**完全修飾名での操作は明示の同意として通る**(コマンドラインに
  完全修飾名か tap 名があれば trust 不要)うえ、その cask が trust.json に**自動登録**され、
  以後の裸名の list / upgrade もそれで通る(いずれも 6.0.9 のソース
  `Library/Homebrew/trust.rb` の `explicitly_allowed?` / `trust_fully_qualified_items!` と、
  untrust 状態からの実測で確認。2026-07-09)。README の
  `brew install --cask bufferings/tap/shiibar-cc` は完全修飾名なので、事前の `brew trust` は不要。
  なお v0.1.0 移行時(2026-07-09)に「アプリだけ入って symlink・postflight が無い」
  中途半端な状態を一度観測した(発生経路は未特定)。アプリを消して `brew install` し直すことで解消した
- **GitHub Actions の Secrets**(shiibar-cc に 6 つ。名前と用途は release.yml / bump-cask.yml):
  値と鍵ファイルの原本はすべて所有者の 1Password にあり、リポジトリにも会話ログにも置かない。
  期限があるのは `TAP_PUSH_TOKEN` だけ(fine-grained PAT。対象 = homebrew-tap のみ・
  権限 = contents: write・期限 1 年): **切れると release publish 後の bump-cask が認証エラーで落ちる**。
  対処は GitHub で PAT を再発行 → `gh secret set TAP_PUSH_TOKEN -R bufferings/shiibar-cc`。
  Developer ID 証明書は約 5 年で期限切れ(1Password のアイテムに期限を記録済み)。
  App Store Connect API キーには期限を設定していない(失効は手動)

## hooks の検証

- hooks は Claude Code プラグイン(`plugin/`)として配布する(DESIGN.md §4.1/§8.19)。
  リポジトリ自体がマーケットプレイスを兼ねるので、ローカルのリポジトリ絶対パスを
  `claude plugin marketplace add <path>` に渡せば push 前でも動作を試せる
  (`claude plugin install shiibar-cc@shiibar-cc` で有効化する)。
  `shiibar-cc` 本体は `cargo build` 後に `target/debug/` を PATH に入れて解決させる

- 実ペイロードの採取: hooks を設定した実セッションで対象イベントを発生させ、受信した実 hook JSON を `fixtures/` に保存する
- 偽装再生: `echo '<hook JSON>' | shiibar-cc report <event>`(実 Claude Code なしで daemon の遷移を再現できる)
- 要検証リスト(DESIGN.md §7-3): `elicitation_*` の実際の意味 / `PostToolUseFailure` の実発火

## macOS 権限まわり

- **M2(focus 初回実行時)**: 「オートメーション(iTerm2 の制御)」の許可ダイアログが出るので許可する。
  誤って拒否した場合: システム設定 → プライバシーとセキュリティ → オートメーション から付け直す。
  ターミナルから実行する CLI と、メニューバーアプリからの実行では**許可が別々に**必要
- **M4(アプリ初回起動時)**: 通知の許可ダイアログ。ad-hoc 署名は再ビルドで権限がリセットされることがある
  (dev-install.sh で安定した署名 ID を使う。DESIGN.md §4.5)
- 「通知が来ない」等の切り分けは `shiibar-cc doctor`(M2 で実装)

## M2 実機スモーク(osascript 権限が要るため人間が行う)

`scripts/dev-install.sh` でバイナリ配置後、素の iTerm2 タブで試すこと
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

- 日常のドッグフーディングはインストール済みの `.app` で行う(`scripts/dev-install.sh` で
  `~/Applications/Shiibar CC.app` を配置。Login Item として登録され、daemon の起動・アタッチ・
  停止はアプリが管理する。DESIGN.md §4.5 / §8.8。launchd には入れない、§8.8)
- コード変更の反映は `scripts/dev-reload.sh`(下記「リリース・インストール」参照)
- daemon 単体をログを見ながら動かしたいとき(daemon とアプリの連携をいじるときなど)は
  手動運用に切り替える: アプリを Quit してから iTerm2 の 1 タブで
  `SHIIBAR_CC_LOG=debug shiibar-ccd --foreground` を動かし、アプリは
  `swift run --package-path app ShiibarCcApp` で起動する。アプリは起動時に既存 daemon に
  アタッチするので、手動 daemon と併用しても壊れない。ただしアプリを Quit すると
  daemon も止まる(§8.8)
- 状態ファイルは `~/.local/state/shiibar-cc/`。壊れたら丸ごと消してよい

## アイコンまわりの開発メモ

利用者には関係ないが、アイコンを触るときに必要になる知識。

- **トレイアイコン**: 描画は `app/Sources/ShiibarCcApp/TrayIconRenderer.swift`(数値は `TrayIconMetrics` に集約)。
  見た目の正は `docs/menubar-design.html`。数値を変えたら menubar-design.html のモック SVG も同じ値に更新する
- **アプリアイコン**: `scripts/generate-app-icon.swift` が唯一の原本。dev-install.sh がこれを実行して
  `.icns` を生成・同梱するので、リポジトリに `.icns` はコミットしない。
  例外は README 用の `docs/assets/app-icon.png`(コミット済みの生成物)— デザインを変えたら
  `swift scripts/generate-app-icon.swift <出力先>` で作り直して差し替えること
- **アイコンが反映されないとき**(キャッシュの層が複数ある):
  1. Info.plist の `CFBundleVersion` は install ごとにタイムスタンプが入る(LaunchServices /
     iconservices のキャッシュが bundle ID + バージョンをキーにするため。固定値だと古い登録が勝ち続ける)
  2. Finder のアイコン: `touch <app>` + `killall Finder`
  3. LaunchServices の登録: `lsregister -f <app>`(パスは
     `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`)
  4. **通知バナーだけ汎用アイコンになる場合**: 通知システムは `~/Library/Preferences/com.apple.ncprefs.plist`
     内のアプリ記録に**バンドルパス**を保持しており、.app をリネームするとこのパスが旧名を指したまま残る
     (許可の照合は署名要件なので通知は届き続け、アイコンだけ壊れる。再起動でも直らない。実測 2026-07-05)。
     対処: `defaults export com.apple.ncprefs` → 旧パスを新パスに置換 → `defaults import` →
     `killall usernoted` → アプリ再起動。plist を直接編集しない(cfprefsd のキャッシュに負ける)。
     なお .app のリネーム(= パスが変わる)でも、**旧パスのバンドルを先に削除してから**同一署名・
     同一 bundle id の新バンドルを**新パスで**起動した場合は、通知システムが ncprefs のパスを
     自動で新パスに追従させることがあり、この手当てが不要なことも(実測 2026-07-05)。
     書き換え前に `defaults export com.apple.ncprefs - | grep -o 'shiibar[^<]*'` で現状を確認するとよい
  5. **新規インストール直後に汎用アイコンのままになることがある**: dev-install.sh が組み立て・署名の
     あと、起動前に `lsregister -f <app>`(上記 3)を自動で実行する。それでも直らない場合の
     手動フォールバックは `killall Dock`(Dock プロセスもアイコンキャッシュを持つ。実測 2026-07-07)
  6. **リリース(brew)版はキャッシュバスターが無い**: dev 版と違い CFBundleVersion がバージョン固定
     (スモークした物 = 公開する物 — 下記「リリース手順」参照)なので、アイコンを変えたリリースを同じマシンに入れると
     旧アイコンのキャッシュが残ることがある。lsregister / `killall usernoted` / `killall Dock` で
     落ちない場合、`brew uninstall` → `brew install` の入れ直し(登録の削除 → 再作成)で解決した
     (通知バナーのアイコンで実測 2026-07-09)。新規マシンには旧キャッシュが無いので利用者影響はない

## リリース・インストール

- `scripts/dev-install.sh`: リリースビルドして `~/Applications/Shiibar CC.app`
  (`SHIIBAR_CC_APP_DIR` で上書き可)を組み立て、安定したローカル署名 ID で署名する
  (再ビルドで通知権限がリセットされないようにするため。DESIGN.md §4.5。ID が無ければ
  `scripts/lib/make-local-signing-identity.sh` で作成する)。`~/.local/bin/`
  (`SHIIBAR_CC_BIN_DIR` で上書き可)には bundle 内バイナリへのシンボリックリンクを配置する。
  最後にアプリを 1 回起動する(Login Item として自己登録。§4.5)。hooks は Claude Code
  プラグインとして配布するため(§4.1/§8.19)、`~/.claude/settings.json` はこのスクリプトが
  一切触らない。`enabledPlugins` に `shiibar-cc@shiibar-cc: true` が無ければ
  `claude plugin marketplace add bufferings/shiibar-cc` → `claude plugin install shiibar-cc@shiibar-cc`
  の 2 コマンドを案内するだけ
- `scripts/dev-uninstall.sh`: 一段のみ(引数を取らない。DESIGN.md §8.20)。`.app`
  (Login Item 登録ごと)・`~/.local/bin/` のシンボリックリンク・state dir
  (`SHIIBAR_CC_STATE_DIR` の既定パス)・`defaults delete cc.shiibar.menubar`・
  ローカル署名 ID(`shiibar-cc-local-signing`、`scripts/lib/signing.sh`)の
  `security delete-certificate`・`tccutil reset AppleEvents cc.shiibar.menubar` を
  常に実行する。hooks の撤去はプラグイン管轄なので `~/.claude/settings.json` は触らず、
  `claude plugin uninstall shiibar-cc` を案内するだけ。通知許可だけはプログラムから削除できない
  ため、システム設定 → 通知 からの手動削除を案内して終わる
- `scripts/dev-reload.sh`: 日常のホットスワップ。デバッグビルド(cargo + swift)を作り、
  インストール済みアプリを Quit し、daemon が確実に終了するのをスクリプト側で保証してから
  (Quit 経由の shutdown 送信は投げっぱなしでプロセス終了と競合して失われ得るため、
  socket への `{"cmd":"shutdown"}` → SIGTERM → SIGKILL の順に確認する)、bundle 内の
  バイナリを差し替え、dev-install.sh と同じ安定した署名 ID で再署名して(`scripts/lib/signing.sh`。
  ID が keychain に無ければ警告付きで ad-hoc にフォールバック)、アプリを再起動する。
  署名 ID が安定しているので、通知権限はリロードをまたいで維持される(§4.5)。
  アプリ未インストールの環境ではビルドのみ行い、手動運用の手順
  (`shiibar-ccd --foreground` + `swift run`)を表示する
- 動作確認は `shiibar-cc doctor`(daemon 疎通・hooks 設定・PATH・osascript 権限を順に表示)

### 正式配布(brew cask)

正式導入経路は `brew install --cask bufferings/tap/shiibar-cc`(arm64 のみ)。cask 定義の正はこの
リポジトリの `packaging/homebrew/shiibar-cc.rb`(`{{VERSION}}` / `{{SHA256}}` プレースホルダ入りの
テンプレート)。tap リポジトリ `bufferings/homebrew-tap` の `Casks/shiibar-cc.rb` へは、リリース publish
時に `.github/workflows/bump-cask.yml` が生成コミットを push する — 手で編集しない。

### リリース手順

タグの前にパイプライン一式をリハーサルしたいとき(初回・secrets を変えたあと)は **dry-run** が使える:
Actions タブ → Release → Run workflow(workflow_dispatch)。実 secrets で署名・公証・staple まで走り、
Release は作らず zip を workflow artifact に置く。

1. リリースコミットで `plugin/.claude-plugin/plugin.json` の `version` をタグと同じ番号に上げる
   (**hooks を変えていなくても**。bump = hooks 配布のゲート — Claude Code は version が変わらない限り
   キャッシュした plugin を使い続ける。DESIGN.md §4.1)。`Cargo.toml` とはタイミングが違う点に注意:
   あちらは前リリースの publish 直後に bump 済み(手順 7)、こちらはリリースコミットで初めて上げる
2. タグ `vX.Y.Z` を push する(タグは **`Cargo.toml` の `[workspace.package]` の version・
   `plugin.json` の version と三点一致必須**。`.github/workflows/release.yml` の `check-version.sh` が
   検査し、不一致ならビルド前に失敗する)
3. Actions が arm64 ビルド → Developer ID 署名(hardened runtime)→ 公証 → staple → zip を行い、
   **draft** の GitHub Release を作る
4. 所有者が draft の zip を実機スモークする
5. スモーク OK なら draft を publish する(この操作が正式な公開)
6. `release: published` をトリガーに `bump-cask.yml` が起動し、公開済みの zip から sha256 を
   再計算して tap の cask を更新する
7. **publish 直後に** `Cargo.toml` の `[workspace.package]` の version を次の番号(まず patch)へ
   bump してコミットする(`plugin.json` は上げない — 次のリリースコミットまで公開済みの番号を保つ)

**公開後のタグは再利用禁止**。公開前に失敗した draft は、そのタグごと削除してよい。

### バージョンの原則

- リポジトリの `Cargo.toml` の version は常に「次に出す番号」を指す
- dev ビルド(`scripts/dev-install.sh`)はそれに `-dev` サフィックスを付けて名乗る
  (About パネルで見分けられる。DESIGN.md §4.5)
- 機能が入るリリースは 0.x を上げる。修正だけのリリースは 0.x.y を上げる
- publish 後はまず patch へ bump しておけばよい。次のリリースの内容が固まった時点で、
  実態(minor か patch か)に合わせて上げ直してよい

### リリースで使う secrets

- `.github/workflows/release.yml`: `DEVELOPER_ID_CERT_P12` / `DEVELOPER_ID_CERT_PASSWORD`
  (Developer ID Application 証明書)/ `APPLE_API_KEY_P8` / `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID`
  (公証用の App Store Connect API キー)
- `.github/workflows/bump-cask.yml`: `TAP_PUSH_TOKEN`(tap リポジトリ `bufferings/homebrew-tap` への
  push 権限)

値の作り方はここには書かない(名前と用途のみ)。

### dev 版と brew 版の切り替え

同居させず、常にどちらか一方にする:

- リリース検証・brew への移行: `./scripts/dev-uninstall.sh` → `brew install --cask bufferings/tap/shiibar-cc`
- 開発に戻る: `brew uninstall --cask shiibar-cc` → `./scripts/dev-install.sh`

署名方式が切り替わる(ローカル自己署名 ↔ Developer ID)ため、切り替えるたびに通知許可と iTerm2
Automation 許可の再確認ダイアログが 1 回ずつ出るのは想定内(切り替えはリリース検証時だけなので頻度は低い)。
