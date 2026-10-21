#!/usr/bin/env bash
# claude-token-pace インストーラ（Linux / macOS / WSL。Windows ネイティブは対象外）
#
# やること:
#   1) 依存チェック（python3, jq）
#   2) スクリプト/ビューアを $TOKEN_PACE_DIR (既定 ~/.claude/token-pace) に配置
#   3) 既定 config.json / biz-hours.json を配置（既存は上書きしない）
#   4) スラッシュコマンド /tpw を ~/.claude/commands に設置
#   5) 定期実行（systemd の user timer、無ければ cron）を設置（bin/scheduler.sh setup）。
#      Claude Code が動いているかに関係なく回る。間隔は TOKEN_PACE_INTERVAL（既定 5min）、
#      TOKEN_PACE_NO_SCHEDULER=1 で省略できる
#   6) statusLine を「ラッパー」に差し替え（バックアップ＋冪等）。ラッパーは元の statusLine の
#      出力をそのまま通しつつ、記録（tick.sh）を 1 分に 1 回まで蹴る。そのとき定期実行が
#      設置したとおりに動いているかを点検し、止まっていれば直す
#   7) uninstall.sh を配置
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TP_DIR="${TOKEN_PACE_DIR:-$HOME/.claude/token-pace}"
CMD_DIR="$HOME/.claude/commands"
SETTINGS="$HOME/.claude/settings.json"
WRAPPER="$TP_DIR/bin/statusline-wrapper.sh"
VERSION="$(cat "$SRC/VERSION" 2>/dev/null || echo "0.0.0")"
OLD_VER="$([[ -f "$TP_DIR/.version" ]] && cat "$TP_DIR/.version" 2>/dev/null || echo "")"

echo "claude-token-pace installer (v$VERSION)"
echo "  source : $SRC"
echo "  target : $TP_DIR"

# 1) 依存
missing=()
command -v python3 >/dev/null 2>&1 || missing+=("python3")
command -v jq      >/dev/null 2>&1 || missing+=("jq")
if (( ${#missing[@]} )); then
  echo "ERROR: 必要な依存がありません: ${missing[*]}" >&2
  echo "  python3 と jq をインストールしてから再実行してください。" >&2
  exit 1
fi

# 2) ファイル配置
mkdir -p "$TP_DIR/bin" "$CMD_DIR"
cp "$SRC/bin/pace-json.py" "$SRC/bin/serve.sh" "$SRC/bin/serve-http.py" \
   "$SRC/bin/credits-fetch.py" "$SRC/bin/codex-scan.py" "$SRC/bin/codex-fetch.py" \
   "$SRC/bin/usage-fetch.py" "$SRC/bin/tick.sh" "$SRC/bin/scheduler.sh" \
   "$TP_DIR/bin/"
chmod +x "$TP_DIR/bin/serve.sh" "$TP_DIR/bin/pace-json.py" \
         "$TP_DIR/bin/serve-http.py" "$TP_DIR/bin/credits-fetch.py" \
         "$TP_DIR/bin/codex-scan.py" "$TP_DIR/bin/codex-fetch.py" \
         "$TP_DIR/bin/usage-fetch.py" "$TP_DIR/bin/tick.sh" "$TP_DIR/bin/scheduler.sh"
cp "$SRC/web/viewer.html" "$TP_DIR/index.html"   # / で開くため index.html として配信
rm -f "$TP_DIR/viewer.html"                       # 旧名の残骸を掃除（アップグレード時）

# 3) 既定設定（ユーザー設定は上書きしない）
[[ -f "$TP_DIR/config.json"    ]] || cp "$SRC/defaults/config.json"    "$TP_DIR/config.json"
[[ -f "$TP_DIR/biz-hours.json" ]] || cp "$SRC/defaults/biz-hours.json" "$TP_DIR/biz-hours.json"

# 4) スラッシュコマンド（設置先を子プロセスに渡すラッパー経由で serve.sh を呼ぶ）
cat > "$TP_DIR/bin/tpw.sh" <<EOF
#!/usr/bin/env bash
# Installed by claude-token-pace. 設置先をビューアとその子プロセスに渡す。
export TOKEN_PACE_DIR="$TP_DIR"
exec bash "$TP_DIR/bin/serve.sh"
EOF
chmod +x "$TP_DIR/bin/tpw.sh"

cat > "$CMD_DIR/tpw.md" <<EOF
---
description: トークン消費ペースをブラウザで表示（ローカルHTTP・自動更新）
allowed-tools: Bash(bash:*)
disable-model-invocation: true
---

!\`bash "$TP_DIR/bin/tpw.sh"\`

上の実行結果を1行だけ報告する（追加の作業はしない）。
EOF

# 5) 定期実行（statusLine と並ぶ記録の契機。Claude Code を使っていなくても回る）
#    設置・撤去・点検は scheduler.sh にまとめてある（共有資源に触る前に所有を確かめる処理も）
TOKEN_PACE_DIR="$TP_DIR" bash "$TP_DIR/bin/scheduler.sh" setup
SCHED="$(cat "$TP_DIR/.scheduler" 2>/dev/null || echo none)"
IVAL="$(cat "$TP_DIR/sched/interval" 2>/dev/null || echo 5)min"

# 6) statusLine ラッパー生成（$TP_DIR は install 時に埋め込み、$json 等は実行時）
#    ラッパーは元の statusLine を遅らせないよう、記録は切り離して起動する
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# Installed by claude-token-pace. 元の statusLine の出力をそのまま通し、記録（tick.sh）を 1 分に 1 回まで蹴る。
json=\$(cat)
TP_DIR="$TP_DIR"
export TOKEN_PACE_DIR="\$TP_DIR"
now=\$(date +%s 2>/dev/null)
last=0
[[ -r "\$TP_DIR/.last_statusline" ]] && last=\$(cat "\$TP_DIR/.last_statusline" 2>/dev/null)
[[ \$last =~ ^[0-9]+\$ ]] || last=0
if [[ \$now =~ ^[0-9]+\$ ]] && (( now - last >= 60 )); then
  printf '%s' "\$now" > "\$TP_DIR/.last_statusline" 2>/dev/null
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "\$TP_DIR/bin/tick.sh" --from statusline </dev/null >/dev/null 2>&1 &
  else
    nohup  bash "\$TP_DIR/bin/tick.sh" --from statusline </dev/null >/dev/null 2>&1 &
  fi
  disown 2>/dev/null || true
fi
if [[ -r "\$TP_DIR/.orig_statusline" ]]; then
  orig=\$(cat "\$TP_DIR/.orig_statusline")
  [[ -n "\$orig" ]] && printf '%s' "\$json" | eval "\$orig"
fi
EOF
chmod +x "$WRAPPER"

# settings.json を編集（バックアップ＋冪等）
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  echo "ERROR: $SETTINGS が不正な JSON です。statusLine を設定できないので中止します。" >&2
  exit 1
fi
CUR=$(jq -r '.statusLine.command // ""' "$SETTINGS")
if [[ "$CUR" == "$WRAPPER" ]]; then
  echo "  statusLine は既にラップ済み（変更なし）"
elif [[ -n "$CUR" && "$CUR" == *"$TP_DIR"* ]]; then
  # このツールのファイルを包んで使っているなど、自動では差し替えられない形
  echo "  注意: statusLine がこのツールのファイルを指しています（$CUR）。変更しません。" >&2
  echo "        statusLine からの記録と定期実行の点検を使うには、statusLine.command を $WRAPPER にしてください。" >&2
else
  ts=$(date +%s 2>/dev/null || echo now)
  cp "$SETTINGS" "$SETTINGS.tokenpace-bak.$ts"
  echo "  backup : $SETTINGS.tokenpace-bak.$ts"
  # 転送用に元コマンド文字列を、復元用に元 statusLine 全体を保存
  jq -r '.statusLine.command // ""' "$SETTINGS" > "$TP_DIR/.orig_statusline"
  jq    '.statusLine // null'        "$SETTINGS" > "$TP_DIR/.orig_statusline.json"
  # 既存 statusLine の他キー(padding等)は保ちつつ type/command を差し替え
  tmp="$SETTINGS.tp.tmp.$$"
  jq --arg w "$WRAPPER" '.statusLine = ((.statusLine // {}) + {type:"command", command:$w})' "$SETTINGS" > "$tmp"
  if [[ -s "$tmp" ]] && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$SETTINGS"
    echo "  statusLine.command -> $WRAPPER"
  else
    rm -f "$tmp"
    echo "ERROR: 生成した settings.json が不正。中止します（バックアップは残っています）。" >&2
    exit 1
  fi
fi
rm -f "$TP_DIR/bin/sampler.sh"    # 旧版の残骸

# 7) uninstall 配置
if [[ -f "$SRC/uninstall.sh" ]]; then
  cp "$SRC/uninstall.sh" "$TP_DIR/uninstall.sh"
  chmod +x "$TP_DIR/uninstall.sh"
fi

# 8) 版数を記録
printf '%s\n' "$VERSION" > "$TP_DIR/.version"

echo ""
if [[ -z "$OLD_VER" ]]; then
  echo "インストール完了: v$VERSION"
elif [[ "$OLD_VER" != "$VERSION" ]]; then
  echo "更新完了: v$OLD_VER → v$VERSION"
else
  echo "再インストール完了: v$VERSION"
fi
if [[ "$SCHED" == "none" ]]; then
  echo "定期実行が設置されていないため、記録されるのは Claude Code の statusLine が表示されているときだけです。"
else
  echo "以降、Claude Code を使っているかに関わらず $IVAL おきに記録されます（statusLine の表示時にも記録します）。"
fi
echo "  ブラウザ表示   : Claude Code で /tpw"
echo "  ポート変更     : $TP_DIR/config.json の \"port\"（または環境変数 TOKEN_PACE_PORT）"
echo "  就業時間の設定 : $TP_DIR/biz-hours.json"
echo "  アンインストール: bash \"$TP_DIR/uninstall.sh\""
