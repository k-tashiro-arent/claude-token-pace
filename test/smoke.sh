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

# 5r) 窓内リセット回帰: resets_at 据え置きで used% が急落したら包絡を張り直す
#     （旧 running_max のままだと 7d がピーク60に張り付いて used_now<20 を満たさず失敗する）
#     install/serve フローに干渉しないよう別ディレクトリで pace-json.py を実行。
RDIR="$HOME/reset-test"
mkdir -p "$RDIR"
python3 - "$RDIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
h5r = now + 3600           # 5h 窓（now 相対）
d7r = now + 3 * 86400      # 7d 窓（リセットが起きても resets_at は据え置き＝同一値）
# 5h: 単調上昇（リセット無し）。 7d: 60 まで上昇 → 3 へ急落 → stale 高値60混入 → 再上昇。
h5 = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80]
d7 = [10, 20, 30, 40, 50, 60, 60, 60, 3, 60, 4, 5, 6, 7, 8, 9]
n = len(d7)
with open(sys.argv[1], "w") as f:
    for i in range(n):
        ts = now - (n - 1 - i) * 60   # 昇順・全て窓内
        f.write(json.dumps({"ts": ts, "h5": h5[i], "h5r": h5r,
                            "d7": d7[i], "d7r": d7r, "sid": "reset-test"}) + "\n")
PY
TOKEN_PACE_DIR="$RDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "reset回帰: pace-json.py が非ゼロ終了"
u7="$(jq -r '.panels[1].used_now' "$RDIR/pace.json")"
u5="$(jq -r '.panels[0].used_now' "$RDIR/pace.json")"
jq -e '.panels[1].used_now != null and .panels[1].used_now < 20' "$RDIR/pace.json" >/dev/null \
  || fail "reset回帰: 7d がピークに張り付き（used_now=$u7, 期待<20＝リセット未検出）"
jq -e '.panels[0].used_now == 80' "$RDIR/pace.json" >/dev/null \
  || fail "reset回帰: 5h(リセット無し)が想定外（used_now=$u5, 期待80）"
ok "窓内リセット検出: 7d 包絡を張り直し (used_now=$u7) / 5h は不変 ($u5)"

# 5s) stale スナップショット回帰: 5h リセット(h5r)が観測時点で過去の行は古い rate_limits
#     スナップショット。7d 窓は長く d7r が現窓と一致してしまうため、除外しないと高い
#     stale 値(下記 d7=40)がスパイクになる。h5r<=ts の行が捨てられ 7d が跳ねないことを検証。
SDIR="$HOME/stale-test"
mkdir -p "$SDIR"
python3 - "$SDIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
h5r_cur = now + 3600       # 新鮮な 5h 窓（未来）
h5r_old = now - 7200       # stale: 2h 過去 → h5r <= ts
d7r = now + 3 * 86400      # 現 7d 窓（stale 行も同じ現窓 d7r を持つ点がミソ）
fresh_d7 = [5, 5, 6, 6, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8]
fresh_h5 = [40, 42, 45, 48, 50, 52, 55, 58, 60, 62, 65, 68, 70, 72]
n = len(fresh_d7)
rows = [{"ts": now - (n - i) * 60, "h5": fresh_h5[i], "h5r": h5r_cur,
         "d7": fresh_d7[i], "d7r": d7r, "sid": "fresh"} for i in range(n)]
# 古いスナップショット: 高い d7=40 だが h5r は過去（＝別の古い 5h 窓）、d7r は現窓
rows.append({"ts": now - (n // 2) * 60, "h5": 95, "h5r": h5r_old,
             "d7": 40, "d7r": d7r, "sid": "stale"})
rows.sort(key=lambda r: r["ts"])
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$SDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "stale回帰: pace-json.py が非ゼロ終了"
maxd7="$(jq -r '.panels[1].used | map(.[1]) | max' "$SDIR/pace.json")"
un7="$(jq -r '.panels[1].used_now' "$SDIR/pace.json")"
jq -e '(.panels[1].used | map(.[1]) | max) < 20 and .panels[1].used_now < 20' "$SDIR/pace.json" >/dev/null \
  || fail "stale回帰: 古いスナップショット(d7=40)が除外されずスパイク (7d系列最大=$maxd7, used_now=$un7, 期待<20)"
ok "stale スナップショット除外: h5r<=ts の古い行(d7=40)を弾き 7d はスパイクせず (系列最大=$maxd7)"

# 5p) プレイバック回帰(5h): 直近7dに重なる 5h 窓が seg5h として並び、窓の切替＝リセットが再現される。
#     連続する 2 つの 5h 窓（前窓 h5 が 90 まで上昇 → 現窓は 5 から再上昇）を用意し、
#     seg5h が古い順に 2 セグメント／後段セグメントが低値から始まる（リセット再現）ことを検証。
PDIR="$HOME/playback-test"
mkdir -p "$PDIR"
python3 - "$PDIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
h5r_a = now - 3600            # 前の 5h 窓（1h 前にリセット済）: 窓=[now-6h, now-1h]
h5r_b = h5r_a + 5 * 3600      # 現在の 5h 窓（now+4h にリセット）: 窓=[now-1h, now+4h]
d7r = now + 3 * 86400
rows = []
# 前窓 A: ts=now-6h..now-2h（全て h5r_a より過去＝新鮮）、h5 は 10→90
for i, h5 in enumerate([10, 30, 50, 70, 90]):
    rows.append({"ts": now - 6 * 3600 + i * 3600, "h5": h5, "h5r": h5r_a,
                 "d7": 20 + i, "d7r": d7r, "sid": "winA"})
# 現窓 B: ts=now-45m..now、h5 は 5→45（リセット後に低値から再上昇）
for i, h5 in enumerate([5, 15, 30, 45]):
    rows.append({"ts": now - 2700 + i * 900, "h5": h5, "h5r": h5r_b,
                 "d7": 26 + i, "d7r": d7r, "sid": "winB"})
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$PDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "playback回帰: pace-json.py が非ゼロ終了"
jq -e 'has("playback") and (.playback | has("start") and has("now") and has("seg5h"))' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: playback(start/now/seg5h) が無い"
jq -e '.playback.seg5h | length == 2' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: seg5h が 2 セグメントでない (len=$(jq -r '.playback.seg5h|length' "$PDIR/pace.json"))"
jq -e '.playback.seg5h | all(has("x0") and has("x1") and has("even") and has("used") and has("reset_label") and (.xmode=="time"))' \
  "$PDIR/pace.json" >/dev/null || fail "playback回帰: 5h seg に必須キー欠落 or xmode!=time"
jq -e '(.playback.seg7d | length >= 1) and (.playback.seg7d | all(has("x0") and has("x1") and has("even") and has("used") and (.xmode=="date")))' \
  "$PDIR/pace.json" >/dev/null || fail "playback回帰: seg7d が無い or 必須キー欠落 or xmode!=date"
segmax="$(jq -r '.playback.seg5h[0].used | map(.[1]) | max' "$PDIR/pace.json")"
segb0="$(jq -r '.playback.seg5h[1].used[0][1]' "$PDIR/pace.json")"
jq -e '(.playback.seg5h[0].used | map(.[1]) | max) >= 80' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: 前窓が高値に達していない (max=$segmax, 期待>=80)"
jq -e '.playback.seg5h[1].used[0][1] <= 20' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: 現窓が低値から始まらない＝リセット未再現 (先頭=$segb0, 期待<=20)"
ok "プレイバック(5h): seg5h=2窓・前窓ピーク($segmax)→現窓は低値開始($segb0)でリセット再現"

# 5q) プレイバック回帰(7d): 直近7dに 7d 窓の境界をまたぐと seg7d が古い順に 2 セグメントになり、
#     後段（現 7d 窓）が低値から始まる＝7d リセットが再現される。h5r は各行 ts より未来にして
#     stale フィルタを通す（そうしないと window_series が全行を捨てる）。
QDIR="$HOME/playback7d-test"
mkdir -p "$QDIR"
python3 - "$QDIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
d7r_a = now - 3600            # 前の 7d 窓（1h 前にリセット済）: 窓=[now-7d-1h, now-1h]
d7r_b = d7r_a + 7 * 86400     # 現在の 7d 窓: 窓=[now-1h, now+7d-1h]
rows = []
# 前窓 A: ts を窓内に散らし d7 は 20→70 まで上昇。h5r=ts+1h（新鮮）
for i, d7 in enumerate([20, 35, 50, 60, 70]):
    ts = now - 6 * 86400 + i * 86400          # now-6d .. now-2d（全て d7r_a より過去）
    rows.append({"ts": ts, "h5": 10 + i, "h5r": ts + 3600,
                 "d7": d7, "d7r": d7r_a, "sid": "d7A"})
# 現窓 B: ts=now-50m..now、d7 は 4→12（リセット後に低値から再上昇）
for i, d7 in enumerate([4, 7, 10, 12]):
    ts = now - 3000 + i * 900
    rows.append({"ts": ts, "h5": 20 + i, "h5r": ts + 3600,
                 "d7": d7, "d7r": d7r_b, "sid": "d7B"})
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$QDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "playback7d回帰: pace-json.py が非ゼロ終了"
jq -e '.playback.seg7d | length == 2' "$QDIR/pace.json" >/dev/null \
  || fail "playback7d回帰: seg7d が 2 窓でない (len=$(jq -r '.playback.seg7d|length' "$QDIR/pace.json"))"
q7max="$(jq -r '.playback.seg7d[0].used | map(.[1]) | max' "$QDIR/pace.json")"
q7b0="$(jq -r '.playback.seg7d[1].used[0][1]' "$QDIR/pace.json")"
jq -e '(.playback.seg7d[0].used | map(.[1]) | max) >= 60' "$QDIR/pace.json" >/dev/null \
  || fail "playback7d回帰: 前 7d 窓が高値に達していない (max=$q7max, 期待>=60)"
jq -e '.playback.seg7d[1].used[0][1] <= 20' "$QDIR/pace.json" >/dev/null \
  || fail "playback7d回帰: 現 7d 窓が低値から始まらない＝リセット未再現 (先頭=$q7b0, 期待<=20)"
ok "プレイバック(7d): seg7d=2窓・前窓ピーク($q7max)→現窓は低値開始($q7b0)で 7d リセット再現"

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
