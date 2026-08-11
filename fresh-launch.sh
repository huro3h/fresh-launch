#!/usr/bin/env bash
# fresh-launch — Chrome系ブラウザを「起動前に最新化」してから開く。
#
# 目的: 利用中に出る「更新して再起動」を避ける。Chromeの更新実体は アップデータが
# ディスク上のアプリ本体を更新する処理で、「再起動」は起動中プロセスを新本体に差し替える
# だけ。よって【閉じている間に更新を当ててから起動】すれば、あの再起動UIは出ない。
#
#   fresh-launch.sh [options] <channel|appname>
#     channel: stable | beta | dev | canary  (または "Google Chrome Dev" 等のフルアプリ名)
#
#   options:
#     --status        更新保留の有無だけ表示(何も変更しない・開かない)
#     --dry-run       実行内容を表示するだけ(更新も open もしない)
#     --no-open       更新は当てるが起動はしない
#     --force         他チャンネルが起動中でも更新を実行する(既定はスキップ)
#     --timeout N     更新完了待ちの上限秒(既定 600)
#     -h, --help
#
# 注意: 対象は Chrome系(Google Updater管理)のみ。Brave等(Sparkle方式)は非対応。
# 注意: 更新は登録アプリ全部(=全チャンネル)に一括で当たる。個別更新はできない。
set -euo pipefail

# 新しい Chrome Updater (Omaha 4)。旧 GoogleSoftwareUpdateAgent は実処理を
# こちらへ投げて即終了するだけのシムなので、本体を直接叩く。
UPDATER_ROOT="$HOME/Library/Application Support/Google/GoogleUpdater"

# 既知の Chrome系チャンネル(他チャンネル起動中の検出に使う)
CHROME_APPS=("Google Chrome" "Google Chrome Beta" "Google Chrome Dev" "Google Chrome Canary")

TIMEOUT=600
DRY_RUN=0
DO_OPEN=1
FORCE=0
MODE="launch"      # launch | status
TARGET=""

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

# チャンネル別名 → アプリ名
resolve_app_name() {
  case "$1" in
    stable|chrome)              echo "Google Chrome" ;;
    beta)                       echo "Google Chrome Beta" ;;
    dev)                        echo "Google Chrome Dev" ;;
    canary)                     echo "Google Chrome Canary" ;;
    *)                          echo "$1" ;;   # フルアプリ名をそのまま
  esac
}

# アプリ名 → アップデータ上の app id(更新結果の突き合わせに使う)
app_id_for() {
  case "$1" in
    "Google Chrome")        echo "com.google.chrome" ;;
    "Google Chrome Beta")   echo "com.google.chrome.beta" ;;
    "Google Chrome Dev")    echo "com.google.chrome.dev" ;;
    "Google Chrome Canary") echo "com.google.chrome.canary" ;;
  esac
}

# アプリ名 → .app の絶対パス
app_bundle() {
  local name="$1" p
  for p in "/Applications/$name.app" "$HOME/Applications/$name.app"; do
    [ -d "$p" ] && { echo "$p"; return 0; }
  done
  return 1
}

# .app → メインFrameworkの Versions ディレクトリ(Current を持つもの)
fw_versions_dir() {
  local app="$1" d
  for d in "$app/Contents/Frameworks/"*" Framework.framework/Versions"; do
    [ -e "$d/Current" ] && { echo "$d"; return 0; }
  done
  return 1
}

# Current が指す版 = ディスク上の最新(=更新で張り替わる)
staged_version() { readlink "$1/Current" 2>/dev/null || true; }

# 起動中ならメインのブラウザプロセスPID(--type= の付く子プロセスは除外)
main_pid() {
  local app="$1" p
  for p in $(pgrep -f "$app/Contents/MacOS/" 2>/dev/null || true); do
    case "$(ps -o command= -p "$p" 2>/dev/null)" in *--type=*) ;; *) echo "$p"; return 0 ;; esac
  done
}

# 起動中プロセスが実際にロードしている Framework 版(通常1つ)
running_version() {
  local pid="$1"
  [ -n "$pid" ] || return 0
  lsof -p "$pid" 2>/dev/null \
    | grep -oE 'Framework\.framework/Versions/[0-9][0-9.]+' \
    | grep -oE '[0-9][0-9.]+' | sort -u | tail -1
}

# 対象以外に起動中の Chrome系チャンネルがあれば、その名前を1行ずつ出す
running_other_channels() {
  local target="$1" name bundle pid
  for name in "${CHROME_APPS[@]}"; do
    [ "$name" = "$target" ] && continue
    bundle="$(app_bundle "$name")" || continue
    pid="$(main_pid "$bundle")"
    [ -n "$pid" ] && echo "$name"
  done
  return 0
}

# アップデータ本体の実体パス。
# Current(シンボリックリンク)経由では実行しない — セットアップ系モードだと
# コピー元と先が同一になり自壊するため、必ず実体の版ディレクトリを使う。
updater_bin() {
  local v b
  v="$(readlink "$UPDATER_ROOT/Current" 2>/dev/null || true)"
  [ -n "$v" ] || return 1
  b="$UPDATER_ROOT/$v/GoogleUpdater.app/Contents/MacOS/GoogleUpdater"
  [ -x "$b" ] || return 1
  echo "$b"
}

# Braveなど非Chrome系のガード
guard_supported() {
  case "$1" in
    *Brave*|*brave*) echo "error: '$1' は Google Updater管理外(Sparkle方式)のため非対応" >&2; return 1 ;;
  esac
}

# 状態を表示。戻り値: 0=停止中 / 1=起動中で最新 / 2=起動中で更新保留あり
report_status() {
  local app="$1" bundle vd staged pid running
  bundle="$(app_bundle "$app")" || { echo "error: アプリが見つからない: $app" >&2; return 3; }
  vd="$(fw_versions_dir "$bundle")" || { echo "error: Framework Versions が見つからない" >&2; return 3; }
  staged="$(staged_version "$vd")"
  pid="$(main_pid "$bundle")"
  running="$(running_version "$pid")"

  echo "対象     : $app"
  echo "ディスク上: ${staged:-?}  (最新=Current)"
  if [ -z "$pid" ]; then
    echo "状態     : 停止中"
    return 0
  fi
  echo "起動中版 : ${running:-?}  (pid $pid)"
  if [ -n "$running" ] && [ "$running" != "$staged" ]; then
    echo "判定     : ⚠ 再起動保留あり（$running → $staged）"
    return 2
  fi
  echo "判定     : 最新で稼働中"
  return 1
}

# 登録アプリ全部の更新を「オンデマンド」で実行する。
# --update-apps は同期実行(完了して終了する)なので、プロセス消滅の推測待ちは不要。
# ※ --update は「アップデータ自身の更新」であって、これではない。叩くと環境を壊す。
run_update() {
  local app_id="$1" bin out pid rc=0 deadline timed_out=0
  bin="$(updater_bin)" || {
    echo "error: GoogleUpdater が見つからない: $UPDATER_ROOT/Current/…" >&2
    echo "  (Google Chrome を一度起動すると自動で再インストールされる)" >&2
    return 3
  }

  echo "更新チェック(オンデマンド)を実行..."
  out="$(mktemp -t fresh-launch)"
  "$bin" --update-apps >"$out" 2>&1 &
  pid=$!

  deadline=$((SECONDS + TIMEOUT))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill "$pid" 2>/dev/null || true
      timed_out=1
      break
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || rc=$?

  if [ "$timed_out" -eq 1 ]; then
    echo "  ⚠ timeout: ${TIMEOUT}秒を超えたため中断した(更新は未完了の可能性あり)"
    rm -f "$out"
    return 1
  fi

  # 対象チャンネルの結果だけ拾う(出力にはNUL等が混ざるので grep -a)
  if [ -n "$app_id" ]; then
    if ! grep -aq "\"$app_id\": update completed successfully" "$out"; then
      echo "  ⚠ $app_id の更新完了行が出力に無い(rc=$rc)。ログ: $UPDATER_ROOT/updater.log"
      rm -f "$out"
      return 1
    fi
  elif [ "$rc" -ne 0 ]; then
    echo "  ⚠ アップデータが rc=$rc で終了した。ログ: $UPDATER_ROOT/updater.log"
  fi

  rm -f "$out"
  return 0
}

launch_flow() {
  local app="$1" bundle vd before after pid app_id others skip_update=0 upd_rc=0
  bundle="$(app_bundle "$app")" || { echo "error: アプリが見つからない: $app" >&2; return 3; }
  vd="$(fw_versions_dir "$bundle")" || { echo "error: Framework Versions が見つからない" >&2; return 3; }
  pid="$(main_pid "$bundle")"
  app_id="$(app_id_for "$app")"

  if [ -n "$pid" ]; then
    # 起動中に本体更新を当てると、避けたいはずの再起動UIの原因になる。更新はしない。
    echo "既に起動中(pid $pid)。起動中の更新は行いません(再起動UIの原因になるため)。"
    report_status "$app" || true
    [ "$DO_OPEN" -eq 1 ] && { [ "$DRY_RUN" -eq 1 ] && echo "[dry-run] open -a \"$app\"" || open -a "$app"; }
    return 0
  fi

  # 更新は全チャンネル一括で当たる。他チャンネルが開いていると、そちらに再起動UIが出る。
  others="$(running_other_channels "$app" | paste -sd, -)"
  if [ -n "$others" ]; then
    if [ "$FORCE" -eq 1 ]; then
      echo "⚠ 他チャンネル起動中: $others — --force 指定のため更新を実行する(そちらに再起動UIが出る)。"
    else
      echo "他チャンネルが起動中のため更新をスキップ: $others"
      echo "  更新は全チャンネル一括で当たるため、起動中のチャンネルに「更新して再起動」が出てしまう。"
      echo "  実行するには全て閉じるか --force を指定する。"
      skip_update=1
    fi
  fi

  before="$(staged_version "$vd")"
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$skip_update" -eq 1 ]; then
      echo "[dry-run] 停止中だが他チャンネル起動中のため更新はスキップ"
    else
      echo "[dry-run] 停止中 → オンデマンド更新($app_id を含む全登録アプリ) → 完了まで同期待ち"
    fi
    echo "[dry-run] 現在ディスク上: ${before:-?}"
    [ "$DO_OPEN" -eq 1 ] && echo "[dry-run] open -a \"$app\""
    return 0
  fi

  if [ "$skip_update" -eq 0 ]; then
    run_update "$app_id" || upd_rc=$?
    after="$(staged_version "$vd")"
    if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
      echo "更新適用: $before → $after"
    elif [ "$upd_rc" -ne 0 ]; then
      # チェックを完走できていないので「最新」と断定してはいけない
      echo "⚠ 更新状態は不明(チェックを完了できなかった)。ディスク上: ${after:-$before}"
    else
      echo "更新なし(最新: ${after:-$before})"
    fi
  else
    after="$before"
  fi

  if [ "$DO_OPEN" -eq 1 ]; then
    open -a "$app"
    echo "起動: $app (${after:-$before})"
  else
    echo "起動せず(--no-open): $app (${after:-$before})"
  fi
}

# --- 引数解析 ---
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    --status)    MODE="status"; shift ;;
    status)      MODE="status"; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --no-open)   DO_OPEN=0; shift ;;
    --force)     FORCE=1; shift ;;
    --timeout)   TIMEOUT="${2:?--timeout に秒数が必要}"; shift 2 ;;
    -*)          echo "unknown option: $1" >&2; usage; exit 2 ;;
    *)           TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { echo "error: 対象(channel か アプリ名)を指定してください" >&2; usage; exit 2; }

APP="$(resolve_app_name "$TARGET")"
guard_supported "$APP" || exit 2

case "$MODE" in
  status)  report_status "$APP" ;;
  launch)  launch_flow "$APP" ;;
esac
