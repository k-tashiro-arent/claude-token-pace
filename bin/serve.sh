#!/usr/bin/env bash
# トークン消費ペースをブラウザでインタラクティブ表示する（Linux / macOS / WSL）。
# /tpw から呼ばれる。
#
# 仕組み: $TOKEN_PACE_DIR を 127.0.0.1 のローカル HTTP で配信し、Canvas 描画の
#         viewer.html をブラウザで開く。viewer は pace.json を数秒ごとに fetch し、
#         generated_at の変化時だけ再描画（now 線は毎秒更新）。pace.json は
#         バックグラウンド再生成で更新されるため自動反映される。
#   ・127.0.0.1 バインド = LAN へは露出しない（ホストからのみ到達）
#   ・ブラウザは通常 localhost をプロキシ迂回するため社内プロキシ環境でも届く
#
# ポート解決: 環境変数 TOKEN_PACE_PORT > config.json の "port" > 既定 8799。
#   指定ポートを優先し、埋まっていれば近傍(+10)を自動スキャンして必ず起動する。
set -u
TP_DIR="${TOKEN_PACE_DIR:-$HOME/.claude/token-pace}"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$BIN_DIR/pace-json.py"
STATE="$TP_DIR/.web_server"
VIEWER="$TP_DIR/index.html"
CONFIG="$TP_DIR/config.json"

mkdir -p "$TP_DIR" 2>/dev/null
rm -f "$TP_DIR/viewer.html" 2>/dev/null   # 旧名の残骸を掃除（/ で開くため index.html を配信）

# 1) pace.json を最新化
python3 "$GEN" 2>/dev/null || true

# 2) viewer.html を用意（無ければパッケージ同梱物から復元）
if [[ ! -f $VIEWER ]]; then
  for cand in "$BIN_DIR/../web/viewer.html" "$TP_DIR/web/viewer.html"; do
    [[ -f $cand ]] && { cp "$cand" "$VIEWER"; break; }
  done
fi

# 3) 希望ポートを解決（env > config.json > 既定 8799）
PORT_PREF="${TOKEN_PACE_PORT:-}"
if [[ -z $PORT_PREF && -r $CONFIG ]]; then
  PORT_PREF=$(python3 -c 'import json,sys
try:
    v=json.load(open(sys.argv[1])).get("port")
    print(int(v) if v is not None else "")
except Exception:
    print("")' "$CONFIG" 2>/dev/null)
fi
[[ $PORT_PREF =~ ^[0-9]+$ ]] || PORT_PREF=8799

# 4) 既存サーバ稼働なら再利用 / なければ希望ポート優先で起動
PORT=""
if [[ -r $STATE ]]; then
  read -r spid sport < "$STATE" 2>/dev/null || true
  if [[ -n ${spid:-} && -n ${sport:-} ]] && kill -0 "$spid" 2>/dev/null \
     && curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$sport/"; then
    PORT=$sport   # 既存サーバを再利用（URL 安定）
  fi
fi

if [[ -z $PORT ]]; then
  # 希望ポートを先頭に、埋まっていれば +9 まで空きスキャン
  PORT=$(python3 -c '
import socket, sys
pref = int(sys.argv[1])
for p in range(pref, pref + 10):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); s.close(); print(p); break
    except OSError:
        pass
else:
    print(pref)
' "$PORT_PREF")
  if command -v setsid >/dev/null 2>&1; then           # macOS には setsid が無いので nohup で代替
    setsid python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$TP_DIR" >/dev/null 2>&1 </dev/null &
  else
    nohup  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$TP_DIR" >/dev/null 2>&1 </dev/null &
  fi
  spid=$!
  disown 2>/dev/null || true
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.1
  done
  printf '%s %s\n' "$spid" "$PORT" > "$STATE"
fi

# 5) 既定ブラウザで開く（WSL/Windows -> powershell.exe, Linux -> xdg-open, macOS -> open）
url="http://localhost:$PORT/"
if command -v powershell.exe >/dev/null 2>&1; then       # WSL / Windows
  powershell.exe -NoProfile -Command "Start-Process '$url'" >/dev/null 2>&1
elif command -v xdg-open >/dev/null 2>&1; then           # Linux
  xdg-open "$url" >/dev/null 2>&1
elif command -v open >/dev/null 2>&1; then               # macOS
  open "$url" >/dev/null 2>&1
fi
echo "ブラウザで $url を開きました（インタラクティブ表示・pace.json更新を自動反映）。server PID=$spid PORT=$PORT"
