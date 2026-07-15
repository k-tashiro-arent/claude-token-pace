#!/usr/bin/env bash
# claude-token-pace インストーラ（Linux / macOS / WSL。Windows ネイティブは対象外）
#
# やること:
#   1) 依存チェック（python3, jq）
#   2) スクリプト/ビューアを $TOKEN_PACE_DIR (既定 ~/.claude/token-pace) に配置
#   3) 既定 config.json / biz-hours.json を配置（既存は上書きしない）
#   4) スラッシュコマンド /tpw を ~/.claude/commands に設置
#   5) statusLine を「ラッパー」に差し替え（バックアップ＋冪等）。
#      ラッパーは JSON を sampler に渡しつつ、元の statusLine 出力をそのまま通す。
#   6) uninstall.sh を配置
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
cp "$SRC/bin/pace-json.py" "$SRC/bin/serve.sh" "$SRC/bin/sampler.sh" "$SRC/bin/serve-http.py" "$TP_DIR/bin/"
chmod +x "$TP_DIR/bin/serve.sh" "$TP_DIR/bin/sampler.sh" "$TP_DIR/bin/pace-json.py" "$TP_DIR/bin/serve-http.py"
cp "$SRC/web/viewer.html" "$TP_DIR/index.html"   # / で開くため index.html として配信
rm -f "$TP_DIR/viewer.html"                       # 旧名の残骸を掃除（アップグレード時）

# 3) 既定設定（ユーザー設定は上書きしない）
[[ -f "$TP_DIR/config.json"    ]] || cp "$SRC/defaults/config.json"    "$TP_DIR/config.json"
[[ -f "$TP_DIR/biz-hours.json" ]] || cp "$SRC/defaults/biz-hours.json" "$TP_DIR/biz-hours.json"

# 4) スラッシュコマンド（serve.sh を絶対パスで指す）
cat > "$CMD_DIR/tpw.md" <<EOF
---
description: トークン消費ペースをブラウザで表示（ローカルHTTP・自動更新）
allowed-tools: Bash(bash:*)
disable-model-invocation: true
---

!\`bash "$TP_DIR/bin/serve.sh"\`

上の実行結果を1行だけ報告する（追加の作業はしない）。
EOF

# 5) statusLine ラッパー生成（$TP_DIR は install 時に埋め込み、$json 等は実行時）
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# Installed by claude-token-pace. statusLine JSON を sampler に渡しつつ元の statusLine を通す。
json=\$(cat)
TP_DIR="$TP_DIR"
printf '%s' "\$json" | bash "\$TP_DIR/bin/sampler.sh" >/dev/null 2>&1 &
disown 2>/dev/null || true
if [[ -r "\$TP_DIR/.orig_statusline" ]]; then
  orig=\$(cat "\$TP_DIR/.orig_statusline")
  [[ -n "\$orig" ]] && printf '%s' "\$json" | eval "\$orig"
fi
EOF
chmod +x "$WRAPPER"

# 6) settings.json を編集（バックアップ＋冪等）
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
if ! jq empty "$SETTINGS" 2>/dev/null; then
  echo "ERROR: $SETTINGS が不正な JSON です。中止します。" >&2
  exit 1
fi
CUR=$(jq -r '.statusLine.command // ""' "$SETTINGS")
if [[ "$CUR" == "$WRAPPER" ]]; then
  echo "  statusLine は既にラップ済み（変更なし）"
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
  if jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS"
    echo "  statusLine.command -> $WRAPPER"
  else
    rm -f "$tmp"
    echo "ERROR: 生成した settings.json が不正。中止します（バックアップは残っています）。" >&2
    exit 1
  fi
fi

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
echo "以降、Claude Code を使うたびに使用量が記録されます。"
echo "  ブラウザ表示   : Claude Code で /tpw"
echo "  ポート変更     : $TP_DIR/config.json の \"port\"（または環境変数 TOKEN_PACE_PORT）"
echo "  就業時間の設定 : $TP_DIR/biz-hours.json"
echo "  アンインストール: bash \"$TP_DIR/uninstall.sh\""
