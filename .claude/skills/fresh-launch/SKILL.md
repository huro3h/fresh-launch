---
name: fresh-launch
description: fresh-launch(Chrome系ブラウザを起動前に最新化してから開く単独スクリプト)を改修・拡張・デバッグするときに使う。Chrome Updater(Omaha 4)のオンデマンド更新の叩き方、更新保留の検出方法、起動中判定、Brave非対応の理由、安全な検証手順を扱う。
---

# fresh-launch 開発メモ

Chrome系ブラウザを「閉じている間に最新化 → 起動」して、利用中の「更新して再起動」を避ける
単独 bash スクリプト（`fresh-launch.sh` 1枚）。他プロジェクトに依存しない単体で完結した構成。

## 中心アイデア

Chromeの更新は **ディスク上のアプリ本体を先に差し替え**、起動中プロセスは古い
Frameworkを掴んだまま → これが「再起動して更新」の状態。よって **停止中に更新を当ててから
起動すれば再起動UIは出ない**。起動中は更新しない（当てると避けたいUIの原因になる）。

## 更新保留の検出（osascript不要・TCC不要・履歴に触れない）

- **ディスク上最新** = `…/<Name> Framework.framework/Versions/Current` の `readlink`。
- **起動中の版** = メインプロセスが実際にロードしている Framework 版を `lsof` で取得
  （`lsof -p <pid> | grep 'Framework.framework/Versions/<X>'`）。
- **保留あり** = 「起動中版 ≠ Current」。
- **落とし穴**: `Versions/` に古い版ディレクトリが残るのは前回更新の残骸。**複数ある=更新待ちではない**。
  必ず「起動中版 vs Current」で比較する（別途行ったmacOSのブラウザ更新状態の調査で確立した判定方法）。
- **メインPIDの取り方**: `pgrep -f "<app>/Contents/MacOS/"` の中から `--type=` の付く子プロセスを
  除いた1つ（ブラウザ本体プロセス）。

## 更新のトリガ — Chrome Updater (Omaha 4) の `--update-apps`

**この環境の更新実体は旧Keystoneではない。** `~/Library/Google/GoogleSoftwareUpdate/` 配下の
`GoogleSoftwareUpdateAgent` と `ksadmin` は、新しい **Chrome Updater（Omaha 4 / `chrome/updater/*`）**
への**互換シム**にすぎない。

### 正しい叩き方（2026-08-11 実機検証で確立）

```sh
# 実体パス。Current(シンボリックリンク)経由では実行しないこと(後述)
V="$(readlink "$HOME/Library/Application Support/Google/GoogleUpdater/Current")"
"$HOME/Library/Application Support/Google/GoogleUpdater/$V/GoogleUpdater.app/Contents/MacOS/GoogleUpdater" --update-apps
```

- スイッチの実体は Chromium の `kUpdateAppsSwitch = "update-apps"`（コメント: *"Updates the apps."*）→
  `MakeAppUpdateApps()`。`UpdateService::Priority::kForeground` で `Update` を呼び、
  **`CheckForUpdatesTask` の定期スロットルを経由しない**（＝毎回ちゃんとチェックが走る）。
- **同期実行**。全登録アプリを処理し終えてから終了する（実測 約2秒／更新なし時）。
  したがって「プロセスが消えるまで待つ」ようなヒューリスティックは不要。
- **標準出力が機械可読**。app id ごとに以下が出る:
  ```
  "com.google.chrome.canary": checking for updates...
  "com.google.chrome.canary": update available, version: X   ← 更新があるときだけ
  "com.google.chrome.canary": updated version: X
  "com.google.chrome.canary": update completed successfully
  Done running `--update-apps`
  ```
  **出力にNUL等の制御文字が混ざる**ので、`grep` は必ず `-a` を付ける（付けないと
  「バイナリファイル」扱いで**何も出力されず**、無出力を異常と誤読する）。
- app id: `com.google.chrome` / `.beta` / `.dev` / `.canary`（＋アップデータ自身のGUID）。
- スクリプトは「対象app idの `update completed successfully` 行があるか」で成否を判定し、
  無ければ「更新状態は不明」と正直に報告する（**「最新」と断定しない**のが重要）。

### ⚠ `GoogleUpdater --update` は絶対に叩かない（環境を壊す）

`kUpdateSwitch = "update"` のコメントは *"Updates the **updater**."* — **アプリの更新ではなく
アップデータ自身の更新**。しかも `GoogleUpdater/Current/…` 経由で実行すると
**コピー元と先が同一**になり、`mac_setup.mm` が先にインストール先を削除 →
`Copying app to '…/<ver>' failed` で終了コード15。結果 **`<ver>/` が消え `Current` がリンク切れ**し、
ユーザー側の自動更新が停止する（2026-08-11 に実際に踏んだ）。

- 復旧方法（実証済み）: **Google Chrome を普通に起動するだけ**。Chromeは起動時にアップデータの
  欠落を検出し、内蔵の `<Chrome.app>/Contents/Frameworks/Google Chrome Framework.framework/
  Versions/<v>/Helpers/GoogleUpdater.app` から自動で再インストールする
  （`ForceInstall … kSuccess`、launchd に `com.google.GoogleUpdater.wake` が再登録される）。
  チケットは `prefs.json` に残るので失われない。再インストール版はChrome内蔵のやや古い版になるが、
  次の `--update-apps` でアップデータ自身が最新へ自己更新される（実際に 150→152 へ戻った）。
- 教訓: **このアップデータのフラグを推測で叩かない**。バイナリの `strings` でスイッチ名を列挙し、
  Chromium の `chrome/updater/constants.h`（値とコメント）と `updater.cc`（どの App にディスパッチ
  されるか）で**意味を裏取りしてから**実行する。実在するスイッチ: `install` `update` `update-apps`
  `ondemand` `wake` `wake-all` `server` `handoff` `healthcheck` `recover` `uninstall` `force-install`
  `app-id` `system` `silent`。

### 旧実装がなぜ動かなかったか（再発防止）

`GoogleSoftwareUpdateAgent -runMode oneshot -userInitiated YES` を使っていたが:

1. エージェントは `GoogleUpdater --wake-all` を**切り離しで起動して0.01秒で自分は終了**する
   シムなので、`pgrep -f GoogleSoftwareUpdateAgent` の完了待ちは**常に空振り**。
   実測で `--timeout 300` 指定にもかかわらず**全体0.13秒**で `open` に到達していた。
2. `--wake-all` は**スロットル**され、チェック自体がスキップされることが多い:
   `check_for_updates_task.cc:51] Skipping UpdateAll: last update was 149 minutes ago. check_delay == 270`
3. 結果、「更新なし」表示は *最新だった* のか *チェックしなかった* のか区別できない無意味な出力だった。

### 調査に使えるログ

- `~/Library/Application Support/Google/GoogleUpdater/updater.log`（`.old` にローテート）。
  `--wake` / `--server` / `UpdateAll` / `ForceInstall` の顛末が残る。判断はここを読んでからにする。
- ただし `--update-apps` の**人間可読な結果行は標準出力**であり、`updater.log` には出ない。
- 登録チケットは `…/GoogleSoftwareUpdate.bundle/Contents/Helpers/ksadmin --print-tickets`。読み取りのみで安全。

## 重要な仕様・制約

- **更新は全チャンネル一括**。特定チャンネルだけ更新はできない（`--update-apps` は登録アプリ全部）。
  → **他のChromeチャンネルを開いたまま実行すると、そちらに「再起動して更新」が出る**。
  そこで `running_other_channels` で検出し、**既定では更新をスキップ**する（`--force` で上書き可）。
  この自己矛盾（避けたいUIを自分で誘発する）を防ぐのが目的。
- **Brave等は非対応**: Sparkle方式。`guard_supported` で `*Brave*` を弾く。
  将来 Brave対応するなら Sparkle のトリガ（アプリ内 `SUScheduledCheckInterval` / `sparkle` CLI等）が別途必要。
- チャンネル別名→アプリ名は `resolve_app_name`、アプリ名→app idは `app_id_for`。
- **macOS に `timeout` コマンドは無い**。`run_update` は `&` ＋ `kill -0` ポーリング ＋ `kill` で自前実装。

## 安全な検証手順

- **status / --dry-run は無害**（読み取りのみ・更新もopenもしない）。まずこれで
  アプリ解決・起動中判定・版検出を確認する。
- **実更新と `open` は状態変更**。テストは「対象を含む全Chrome系を閉じた状態」で、
  ユーザーの明示的合意のもとで行う（他チャンネルへの副作用を避けるため）。
- set -e/-u 前提。`main_pid`/`running_version` は該当なしでも空を返して成功する作り。
- **検証コマンドが無出力だったときは、結論を出す前に終了コードと標準エラーを必ず確認する。**
  この検証中、存在しない `timeout` コマンドと `grep` のバイナリ判定の2回、
  無出力を「異常」と誤読しかけた。
- ブラウザの「終了したつもり」に注意。ウィンドウを閉じてもプロセスが残ることがあるので、
  実更新の前に `pgrep -lf "Contents/MacOS/Google Chrome"` で必ず確認する。

## 将来のアイデア

- 更新が実際に保留のときだけ更新を走らせる（毎回のネット確認による起動遅延を避ける）スロットル。
  ただし `--update-apps` は更新なしなら約2秒で終わるので、優先度は低い。
- Brave(Sparkle)対応。
- リモートから叩けるエンドポイント化（アップデータは当該ユーザーのGUIセッション文脈が要る点に注意）。
