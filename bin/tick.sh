#!/usr/bin/env bash
# 記録の入口。契機は 2 つあり、どちらから呼ばれても同じ処理をする:
#   tick.sh --from timer       systemd の timer / cron から（Claude Code を使っていなくても回る）
#   tick.sh --from statusline  Claude Code の statusLine から（statusline-wrapper.sh が 1 分に 1 回まで蹴る）
# どちらの契機でも、使用量は API から取得する。statusLine の契機では、標準入力に来た
# statusLine の JSON の rate_limits も記録する（API が 429 で休んでいる間も記録を途切れさせないため）。
# 各処理は .last_* の印で間引くので、契機が重なっても取得の頻度は上がりすぎない。
#
# statusLine から呼ばれたときは、定期実行が設置したとおりに動いているかも点検し、
# 異常があれば直す（scheduler.sh check --repair。10 分に 1 回まで）。
#
# systemd の Type=oneshot は、主プロセスが終わると同じ cgroup に残った子も止める。
# そのため、ここでは各処理をバックグラウンドにせず前面で順に実行する。
#
# 実行の結果は $TOKEN_PACE_DIR/tick.log に 1 行ずつ残す（記録されないときの切り分け用。
# cron の経路では標準出力がメールに回ってしまうので、画面には出さずここだけに書く）。
set -u
TP_DIR="${TOKEN_PACE_DIR:-$HOME/.claude/token-pace}"
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FROM="manual"
[[ ${1:-} == --from && -n ${2:-} ]] && FROM="$2"
SCHED_CHECK_INTERVAL=600
CREDITS_INTERVAL=300
CODEX_INTERVAL=120
PLOT_INTERVAL=180
LOG="$TP_DIR/tick.log"
LOG_MAX=600            # これを超えたら
LOG_KEEP=300           # この行数まで切り詰める

mkdir -p "$TP_DIR" 2>/dev/null
printf -v _now '%(%s)T' -1 2>/dev/null || _now=$(date +%s 2>/dev/null)
[[ $_now =~ ^[0-9]+$ ]] || exit 0

log() {
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S 2>/dev/null || printf '%s' "$_now")" "$*" >> "$LOG" 2>/dev/null
}

# 名前つきで実行し、終了コードと（あれば）出力の 1 行目を記録する
run() {
  local name="$1"; shift
  local out rc
  out="$("$@" 2>&1 9>&-)"; rc=$?   # 子に排他の fd を渡さない（居残ると以後の tick が全部省略される）
  if [[ $rc -eq 0 && -z $out ]]; then
    log "$name ok"
  else
    log "$name rc=$rc ${out%%$'\n'*}"
  fi
  return 0
}

# 経過を見て印を更新する（経っていれば 0 を返す）
due() {
  local stamp="$TP_DIR/$1" span="$2" last=0
  [[ -f $stamp ]] && last=$(<"$stamp")
  [[ $last =~ ^[0-9]+$ ]] || last=0
  (( _now - last < span )) && return 1
  printf '%s' "$_now" > "$stamp"
  return 0
}

# timer が動いている証拠として、timer からの起動時刻を残す（scheduler.sh check が見る）。
# 下の排他で処理を飛ばしたときも timer 自体は動いているので、先に残す。
[[ $FROM == timer ]] && printf '%s' "$_now" > "$TP_DIR/.last_timer_tick"

# statusLine の値の記録も、下の排他で捨てられないよう先に行う（API の間引き・休止とは無関係）。
# 端末から手で --from statusline を付けて起動したときは標準入力を待たない。
if [[ $FROM == statusline && ! -t 0 ]]; then
  out=$(python3 "$BIN_DIR/usage-fetch.py" --statusline 2>&1); slrc=$?
  # 記録できた・rate_limits が無いは書かない（1 分おきに来るのでログが埋まる）
  [[ $slrc -eq 1 ]] && log "statusLine の値を読めず rc=${slrc} ${out%%$'\n'*}"
fi

# 2 つの契機が重なったら、後から来た方は何もしない
if command -v flock >/dev/null 2>&1; then
  exec 9>"$TP_DIR/.tick.lock"
  flock -n 9 || { log "契機=$FROM 別の tick が実行中のため省略"; exit 0; }
else
  # macOS には flock が無いので mkdir の排他で代える（10 分より古い印は落ちた残骸とみなす）
  LOCKD="$TP_DIR/.tick.lock.d"
  if ! mkdir "$LOCKD" 2>/dev/null; then
    if [[ -n "$(find "$LOCKD" -maxdepth 0 -mmin +10 2>/dev/null)" ]]; then
      rmdir "$LOCKD" 2>/dev/null; mkdir "$LOCKD" 2>/dev/null \
        || { log "契機=$FROM 別の tick が実行中のため省略"; exit 0; }
    else
      log "契機=$FROM 別の tick が実行中のため省略"; exit 0
    fi
  fi
  trap 'rmdir "$LOCKD" 2>/dev/null' EXIT
fi

# 0) statusLine からの起動時は、定期実行の点検と修理
if [[ $FROM == statusline ]] && due .last_sched_check "$SCHED_CHECK_INTERVAL"; then
  out=$(bash "$BIN_DIR/scheduler.sh" check --repair 2>&1 9>&-); crc=$?
  if [[ $crc -eq 0 ]]; then
    log "scheduler 点検 異常なし"
  else
    while IFS= read -r l; do [[ -n $l ]] && log "scheduler $l"; done <<< "$out"
  fi
fi

# 1) レート枠（5h/7d）。間引きは usage-fetch.py 自身が .last_usage で行う
out=$(python3 "$BIN_DIR/usage-fetch.py" 2>&1 9>&-); urc=$?
case "$urc" in
  0) log "usage 記録した（契機=${FROM}）" ;;
  2) # statusLine の契機は 1 分おきに来るので、間引いただけのときは書かない（ログが埋まる）
     [[ $FROM == statusline ]] || log "usage 間引き中（前回から間がない、または 429 のバックオフ中。契機=${FROM}）" ;;
  *) log "usage 取得できず rc=$urc 契機=$FROM ${out%%$'\n'*}" ;;
esac

# 2) 月次クレジット枠
due .last_credits "$CREDITS_INTERVAL" && run credits python3 "$BIN_DIR/credits-fetch.py"

# 3) Codex のレート枠（ログ走査と app-server の 2 経路）
if due .last_codex "$CODEX_INTERVAL"; then
  run codex-scan  python3 "$BIN_DIR/codex-scan.py"
  run codex-fetch python3 "$BIN_DIR/codex-fetch.py"
fi

# 4) 描画用の pace.json を作り直す
due .last_plot "$PLOT_INTERVAL" && run plot python3 "$BIN_DIR/pace-json.py"

# ログが伸びすぎたら末尾だけ残す
if [[ -f $LOG ]]; then
  lines=$(wc -l < "$LOG" 2>/dev/null | tr -d '[:space:]')
  if [[ $lines =~ ^[0-9]+$ ]] && (( lines > LOG_MAX )); then
    tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
fi
exit 0
