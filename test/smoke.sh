#!/usr/bin/env bash
# claude-token-pace インストール一気通貫スモークテスト（CI / ローカル共用）。
#
# 隔離した一時 HOME に対して以下を検証する。実環境(~/.claude)には一切触れない:
#   install → statusLine ラッパー化 → 記録(sampler) → pace.json 生成
#         → serve.sh で / と /pace.json を配信 → 冪等性 → uninstall で復元
#
# 依存: bash / python3 / jq / curl。bash 3.2 (macOS 既定) でも動くよう配慮。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRV_PID=""
TMPHOME=""
TP_DIR=""

# インストール経路: direct = install.sh 直叩き / bootstrap = curl ワンライナー経路
# （bootstrap はローカル checkout 自身を clone させる。REF はブランチ/タグ名）
MODE="${SMOKE_INSTALL_MODE:-direct}"
BOOT_REPO="file://$REPO"
BOOT_REF="${SMOKE_BOOTSTRAP_REF:-main}"

# --- 隔離環境（最重要: 実 HOME を絶対に汚さない/消さない）---
TMPHOME="$(mktemp -d 2>/dev/null || mktemp -d -t tokenpace)"
if [ -z "$TMPHOME" ] || [ ! -d "$TMPHOME" ]; then echo "FATAL: mktemp -d failed"; exit 1; fi

cleanup() {
  # 起動したテストサーバを確実に停止（本物の /tpw サーバは別 HOME なので無関係）
  if [ -n "${SRV_PID:-}" ]; then kill "$SRV_PID" 2>/dev/null || true; fi
  if [ -n "${TP_DIR:-}" ] && [ -r "$TP_DIR/.web_server" ]; then
    read -r _p _ < "$TP_DIR/.web_server" 2>/dev/null || true
    if [ -n "${_p:-}" ]; then kill "$_p" 2>/dev/null || true; fi
  fi
  # 一時 HOME のみ削除（空なら削除しない = rm -rf "" 事故の防止）
  if [ -n "${TMPHOME:-}" ] && [ -d "${TMPHOME:-}" ]; then rm -rf "$TMPHOME"; fi
}
trap cleanup EXIT

export HOME="$TMPHOME"
TP_DIR="$HOME/.claude/token-pace"
SETTINGS="$HOME/.claude/settings.json"
WRAPPER="$TP_DIR/bin/statusline-wrapper.sh"

fail() { echo "❌ FAIL: $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }

# 選択された経路でインストールする（direct / bootstrap 共通のエントリ）。
# stdout は抑止するが stderr は残す（失敗時にエラーを見えるように）。
do_install() {
  if [ "$MODE" = "bootstrap" ]; then
    TOKEN_PACE_REPO="$BOOT_REPO" TOKEN_PACE_REF="$BOOT_REF" bash "$REPO/bootstrap.sh" >/dev/null
  else
    bash "$REPO/install.sh" >/dev/null
  fi
}

# --- ブラウザ自動起動を無効化（powershell.exe/xdg-open/open を no-op に差し替え）---
# serve.sh の起動カスケードが実ブラウザを開かないよう PATH 先頭にダミーを置く。
mkdir -p "$HOME/.claude/commands" "$HOME/fakebin"
for op in powershell.exe xdg-open open; do
  printf '#!/bin/sh\nexit 0\n' > "$HOME/fakebin/$op"
  chmod +x "$HOME/fakebin/$op"
done
export PATH="$HOME/fakebin:$PATH"

# 既存 statusLine を仕込む（ラッパーがこれを転送することを検証するため）
jq -n '{statusLine:{type:"command",command:"echo ORIG-STATUSLINE-OK"}}' > "$SETTINGS"

if [ "$MODE" = "bootstrap" ]; then
  echo "== smoke: HOME=$HOME  mode=bootstrap  repo=$BOOT_REPO  ref=$BOOT_REF =="
else
  echo "== smoke: HOME=$HOME  mode=direct =="
fi

# 1) install（direct=install.sh / bootstrap=curl ワンライナー経路）
do_install || fail "インストール($MODE) が非ゼロ終了"
[ -x "$TP_DIR/bin/serve.sh" ]    || fail "serve.sh 未配置"
[ -x "$TP_DIR/bin/sampler.sh" ]  || fail "sampler.sh 未配置"
[ -x "$TP_DIR/bin/pace-json.py" ]|| fail "pace-json.py 未配置"
[ -f "$TP_DIR/bin/serve-http.py" ]|| fail "serve-http.py 未配置"
[ -f "$TP_DIR/index.html" ]      || fail "index.html 未配置"
[ -f "$HOME/.claude/commands/tpw.md" ] || fail "/tpw コマンド未設置"
got_wrap="$(jq -r '.statusLine.command' "$SETTINGS")"
[ "$got_wrap" = "$WRAPPER" ] || fail "statusLine がラッパー化されていない (got: $got_wrap)"
[ "$(cat "$TP_DIR/.orig_statusline")" = "echo ORIG-STATUSLINE-OK" ] || fail "元 statusLine が保存されていない"
ok "install($MODE): ファイル配置・statusLine ラッパー化・元コマンド保存"

# 2) 実際の statusLine JSON（resets_at は now 相対にしてサンプルが窓内に入るようにする）
now="$(date +%s)"
five="$((now + 3600))"; seven="$((now + 3 * 86400))"
JSON="$(jq -n --argjson f "$five" --argjson s "$seven" '{
  context_window:{total_input_tokens:120000,total_output_tokens:8000,used_percentage:34},
  cost:{total_cost_usd:12.34},
  model:{display_name:"Opus 4.8",id:"claude-opus-4-8"},
  effort:{level:"high"},thinking:{enabled:false},fast_mode:false,
  cwd:"/tmp",
  rate_limits:{five_hour:{used_percentage:62,resets_at:$f},
               seven_day:{used_percentage:41,resets_at:$s}},
  session_id:"ci-smoke"}')"

# 3) ラッパー発火（元 statusLine の転送 ＋ サンプリング起動を一度に検証）
out="$(printf '%s' "$JSON" | bash "$WRAPPER")"
case "$out" in
  *ORIG-STATUSLINE-OK*) ok "ラッパーが元 statusLine 表示を転送" ;;
  *) fail "ラッパーが元 statusLine を転送しない (got: $out)" ;;
esac

# 4) 記録の確認（ラッパーは sampler をバックグラウンド実行するので固定 sleep せずポーリング）
deadline="$((now + 20))"
rows=0
while [ "$(date +%s)" -le "$deadline" ]; do
  if [ -f "$TP_DIR/pace.jsonl" ]; then
    rows="$(wc -l < "$TP_DIR/pace.jsonl" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$rows" ] && [ "$rows" -ge 1 ] && break
  fi
  sleep 0.3
done
if [ -z "$rows" ] || [ "$rows" -lt 1 ]; then fail "20秒以内に pace.jsonl へ記録されなかった"; fi
tail -1 "$TP_DIR/pace.jsonl" | jq -e 'has("ts") and has("h5") and has("d7")' >/dev/null \
  || fail "記録行に必要フィールドが無い"
ok "sampler が有効な行を記録 (pace.jsonl=$rows 行)"

# 5) pace-json.py が妥当な pace.json を生成
python3 "$TP_DIR/bin/pace-json.py" || fail "pace-json.py が非ゼロ終了"
[ -f "$TP_DIR/pace.json" ] || fail "pace.json 未生成"
jq -e '.panels | length == 2'   "$TP_DIR/pace.json" >/dev/null || fail "pace.json の panels が 2 でない"
jq -e '.panels | all(has("used"))' "$TP_DIR/pace.json" >/dev/null || fail "panel に used が無い"
jq -e 'has("generated_at")'     "$TP_DIR/pace.json" >/dev/null || fail "pace.json に generated_at が無い"
ok "pace-json.py が妥当な pace.json を生成 (panels=2)"

# 6) serve.sh が / と /pace.json を配信
bash "$TP_DIR/bin/serve.sh" >/dev/null || fail "serve.sh が非ゼロ終了"
[ -r "$TP_DIR/.web_server" ] || fail ".web_server が記録されていない"
read -r SRV_PID PORT < "$TP_DIR/.web_server"
if [ -z "${SRV_PID:-}" ] || [ -z "${PORT:-}" ]; then fail ".web_server の内容が不正"; fi
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
[ "$code" = "200" ] || fail "GET / が $code"
body="$(curl -s "http://127.0.0.1:$PORT/")"
case "$body" in
  *"Token consumption pace"*) : ;;
  *) fail "GET / がビューア HTML を返さない" ;;
esac
pcode="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/pace.json")"
[ "$pcode" = "200" ] || fail "GET /pace.json が $pcode"
curl -s "http://127.0.0.1:$PORT/pace.json" | jq -e '.panels | length == 2' >/dev/null \
  || fail "配信された /pace.json が不正"
ok "serve.sh が / と /pace.json を配信 (port=$PORT pid=$SRV_PID)"

# 6b) ハードニング: 記録ファイル/元 statusLine は配信しない（ホワイトリスト外は 404）
for badpath in /pace.jsonl /.orig_statusline /config.json; do
  bc="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$badpath")"
  [ "$bc" = "404" ] || fail "非公開パス $badpath が配信された (HTTP $bc)"
done
# 6c) ハードニング: 別 Host（DNS リバインド）は 403 で拒否
hc="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "http://127.0.0.1:$PORT/pace.json")"
[ "$hc" = "403" ] || fail "異なる Host を拒否しない (HTTP $hc)"
ok "配信は index.html/pace.json に限定・別 Host を拒否（DNS リバインド対策）"

# 7) 冪等性: 2 回目の install はラッパーを二重化せず、元コマンドも上書きしない
do_install || fail "2 回目のインストール($MODE) が失敗"
[ "$(jq -r '.statusLine.command' "$SETTINGS")" = "$WRAPPER" ] || fail "冪等性: statusLine が変化した"
[ "$(cat "$TP_DIR/.orig_statusline")" = "echo ORIG-STATUSLINE-OK" ] \
  || fail "冪等性: 元コマンドが上書きされた（転送ループの原因になる）"
ok "install は冪等（二重ラップなし・元コマンド保持）"

# 8) uninstall が statusLine を復元しコマンド/サーバを片付ける
bash "$TP_DIR/uninstall.sh" >/dev/null || fail "uninstall.sh が失敗"
restored="$(jq -r '.statusLine.command' "$SETTINGS")"
[ "$restored" = "echo ORIG-STATUSLINE-OK" ] || fail "uninstall が元 statusLine を復元しない (got: $restored)"
[ ! -f "$HOME/.claude/commands/tpw.md" ] || fail "uninstall が /tpw を削除しない"
if kill -0 "$SRV_PID" 2>/dev/null; then fail "uninstall がサーバを停止しない (pid $SRV_PID 生存)"; fi
SRV_PID=""
ok "uninstall: statusLine 復元・/tpw 削除・サーバ停止"

echo "🎉 smoke test PASSED"
