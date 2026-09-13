# fresh-launch 再開メモ

## 現在地（2026-08-11 更新）

- **更新パートの再実装が完了し、E2Eで動作を確認済み。**
  - 旧実装（`GoogleSoftwareUpdateAgent -runMode oneshot`）は**完全に空振り**していた。実体は
    Chrome Updater（Omaha 4）で、エージェントはシム。詳細は project skill 参照。
  - 新実装は `GoogleUpdater --update-apps`（同期・スロットル回避・アプリ別に結果を出力）。
  - 対象チャンネルの `update completed successfully` 行を確認できたときだけ結果を断定し、
    確認できなければ「更新状態は不明」と表示する。
- 検証済み: `--help` / `status` / `--dry-run` / Braveガード / 対象自身が起動中の経路 /
  他チャンネル起動中のスキップ / `--force` / タイムアウト経路 / `--no-open` / 実E2E（canary起動）。
- 実測: 更新なしのケースで約2秒（旧実装は待たずに0.13秒で `open` していた）。

## 次の一手

**次回はここから: 全Chrome系を閉じた状態で `./fresh-launch.sh canary` を実行する。**
Canaryは日次ビルドなので、日をまたげば更新が降りている見込み。確認したいのは2点:

- `更新適用: X → Y` が表示されること（＝実更新ケースを初めて通る）
- その後の起動で「更新して再起動」が **出ない** こと（＝このツールの存在意義そのもの）

実行前に `pgrep -lf "Contents/MacOS/Google Chrome"` で全チャンネルの停止を必ず確認する
（ウィンドウを閉じてもプロセスが残ることがある）。

その後:

1. 上記が確認できたら、CHANGELOG.md + SemVer を導入して `1.0.0` を切る。
   **それまではアルファ版扱い**（中心機能がまだ実地で検証できていないため、バージョンは付けない）。
2. 起動導線への紐づけ（alias / ショートカット / Raycast など）。
3. （将来）Brave(Sparkle)対応。

（完了済み: `git init` ＋ 初回コミット ＋ `git@github.com:huro3h/fresh-launch.git` へ push）

## 最重要の注意

- **`GoogleUpdater --update` は絶対に叩かない**。アプリ更新ではなく**アップデータ自身**のセットアップで、
  `Current/` 経由だとインストール先を削除して失敗し、**ユーザー側の自動更新が停止する**
  （2026-08-11 に実際に踏んだ）。復旧は「Google Chrome を普通に起動する」だけでよい。
  使うのは `--update-apps`。
- アップデータのフラグを**推測で実行しない**。`strings` で列挙し、Chromium の
  `chrome/updater/constants.h` と `updater.cc` で裏を取ってから。
- 更新は**全チャンネル一括**。実更新を伴うテストは Chrome系をすべて閉じてから
  （ウィンドウを閉じてもプロセスが残ることがあるので `pgrep` で確認する）。
- macOS に `timeout` コマンドは無い。`grep` は制御文字混じりの出力を黙って捨てる（`-a` を付ける）。
  どちらも「無出力＝異常」と誤読する原因になった。
