#!/usr/bin/env bash
# statusLine の JSON を stdin で受け取り、レート枠 used%(5h/7d) を pace.jsonl に記録する。
# install.sh が仕込む statusLine ラッパーからバックグラウンドで呼ばれる想定。
#
#   ・SAMPLE_INTERVAL 秒に 1 回だけ記録（statusLine は高頻度に呼ばれるため間引く）
#   ・PLOT_INTERVAL 秒に 1 回 pace.json を再生成（デタッチ起動で非ブロッキング）
#   ・rate_limits が両方 null のとき（API 応答前など）は記録しない
# 依存: jq / python3
set -u
TP_DIR="${TOKEN_PACE_DIR:-$HOME/.claude/token-pace}"
GEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pace-json.py"
SAMPLE_INTERVAL=30
PLOT_INTERVAL=180

mkdir -p "$TP_DIR" 2>/dev/null
command -v jq >/dev/null 2>&1 || exit 0

json=$(cat)
[[ -z $json ]] && exit 0

printf -v _now '%(%s)T' -1 2>/dev/null || _now=""
[[ -z $_now ]] && _now=$(date +%s 2>/dev/null)
[[ $_now =~ ^[0-9]+$ ]] || exit 0

# サンプル間引き
_last=0; [[ -f "$TP_DIR/.last_sample" ]] && _last=$(<"$TP_DIR/.last_sample")
[[ $_last =~ ^[0-9]+$ ]] || _last=0
(( _now - _last < SAMPLE_INTERVAL )) && exit 0
printf '%s' "$_now" > "$TP_DIR/.last_sample"   # 即スタンプして多重記録を抑止

row=$(printf '%s' "$json" | jq -rc --argjson now "$_now" '
  if (.rate_limits.five_hour.used_percentage // null) == null
     and (.rate_limits.seven_day.used_percentage // null) == null
  then empty
  else {ts:$now,
        h5:(.rate_limits.five_hour.used_percentage // null),
        h5r:(.rate_limits.five_hour.resets_at // null),
        d7:(.rate_limits.seven_day.used_percentage // null),
        d7r:(.rate_limits.seven_day.resets_at // null),
        cost:(.cost.total_cost_usd // null),
        sid:(.session_id // .sessionId // null)} end' 2>/dev/null)
[[ -z $row ]] && exit 0

if command -v flock >/dev/null 2>&1; then      # 排他は flock がある環境のみ（macOS 標準には無い）
  ( flock 9; printf '%s\n' "$row" >>"$TP_DIR/pace.jsonl" ) 9>"$TP_DIR/.lock"
else
  printf '%s\n' "$row" >>"$TP_DIR/pace.jsonl"
fi

# pace.json 再生成の間引き（デタッチ起動で status line を遅延させない）
_plast=0; [[ -f "$TP_DIR/.last_plot" ]] && _plast=$(<"$TP_DIR/.last_plot")
[[ $_plast =~ ^[0-9]+$ ]] || _plast=0
if (( _now - _plast >= PLOT_INTERVAL )); then
  printf '%s' "$_now" > "$TP_DIR/.last_plot"
  if command -v setsid >/dev/null 2>&1; then    # macOS には setsid が無いので nohup で代替
    setsid python3 "$GEN" >/dev/null 2>&1 </dev/null &
  else
    nohup  python3 "$GEN" >/dev/null 2>&1 </dev/null &
  fi
fi
exit 0
