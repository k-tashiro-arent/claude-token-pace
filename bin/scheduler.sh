#!/usr/bin/env bash
# 定期実行（systemd の user timer、無ければ cron）の設置・撤去・点検。
#
#   scheduler.sh setup            設置して .scheduler に記録する（install.sh から）
#   scheduler.sh remove           この設置先の登録だけを外す（uninstall.sh / TOKEN_PACE_NO_SCHEDULER）
#   scheduler.sh check [--repair] 設置したとおりに動いているかを見る。--repair なら直す
#                                 （statusLine を契機に動いた tick.sh から呼ばれる）
#
# systemd の user manager と crontab は uid 単位の共有資源で、HOME を差し替えても隔離できない。
# そのため、止める・消す・直す前に、対象がこの設置先（$TP_DIR）の tick.sh を指していることを
# 必ず確かめる。確かめられないものには触らず、そう出力する。
#
# check の出力は 1 行 1 件で、終了コードは 0 = 問題なし / 1 = 問題あり（直したかどうかは出力に書く）。
set -u
TP_DIR="${TOKEN_PACE_DIR:-$HOME/.claude/token-pace}"
TICK="$TP_DIR/bin/tick.sh"
NAME=claude-token-pace
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
MASTER="$TP_DIR/sched"     # 設置した内容の控え。点検で比べ、直すときに書き戻す
TAG="# claude-token-pace"

now() { local t; printf -v t '%(%s)T' -1 2>/dev/null || t=$(date +%s); printf '%s' "$t"; }

# 標準入力のどこかの行が、この設置先の tick.sh を指しているか
# （unit / systemctl show は「 <path> 」、cron 行は「"<path>"」の形で現れる）
mentions_tick() {
  local l
  while IFS= read -r l; do
    case "$l " in *" $TICK "*|*"\"$TICK\""*) return 0 ;; esac
  done
  return 1
}

# crontab のうち、この設置先の tick.sh を呼ぶ行だけを落とす（別の設置先の行は残す）
drop_own_cron() {
  awk -v a=" $TICK " -v b="\"$TICK\"" -v tag="$TAG" '
    { t = $0 " " }
    !(substr($0, length($0) - length(tag) + 1) == tag && (index(t, a) || index(t, b)))'
}

systemd_usable() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}
# ユニットファイル（この UNIT_DIR にあるもの）がこの設置先のものか
own_unit_file() { [[ -f $UNIT_DIR/$NAME.service ]] && mentions_tick < "$UNIT_DIR/$NAME.service"; }
# systemd が読み込んでいるユニットがこの設置先のものか（HOME や XDG_CONFIG_HOME に左右されない）
own_loaded_unit() { systemctl --user show -p ExecStart "$NAME.service" 2>/dev/null | mentions_tick; }
loaded_state() { systemctl --user show -p LoadState --value "$NAME.service" 2>/dev/null; }

# crontab -l を読む。読めない（「crontab が無い」以外の失敗）ときは 1 を返す。
# 読めないまま書き戻すと既存の crontab を空で上書きしてしまうため。
read_crontab() {
  local out rc
  out="$(crontab -l 2>&1)"; rc=$?
  if (( rc != 0 )); then
    case "$out" in *"no crontab"*) return 0 ;; esac
    return 1
  fi
  printf '%s\n' "$out"
}

# ---- setup ----
make_master() {
  local ival="${TOKEN_PACE_INTERVAL:-5min}" n spath py3 cdx
  # 受け付けるのは「N分」だけ。cron は分単位でしか書けず、他の単位を許すと
  # systemd と cron で間隔の意味が食い違うため。
  if [[ $ival =~ ^([0-9]+)(min)?$ ]]; then
    n="${BASH_REMATCH[1]}"
  else
    echo "  TOKEN_PACE_INTERVAL=$ival は分で指定してください（例 5min）。既定の 5min を使います" >&2
    n=5
  fi
  [[ $n -ge 1 ]] || n=5
  # systemd も cron も PATH が最小限なので、python3（と codex）の場所を明示する
  spath="/usr/local/bin:/usr/bin:/bin"
  py3="$(command -v python3 2>/dev/null)"; [[ -n $py3 ]] && spath="$(dirname "$py3"):$spath"
  cdx="$(command -v codex 2>/dev/null)";   [[ -n $cdx ]] && spath="$(dirname "$cdx"):$spath"

  mkdir -p "$MASTER"
  printf '%s\n' "$n" > "$MASTER/interval"
  {
    echo "[Unit]"
    echo "Description=claude-token-pace: record Claude and Codex usage windows"
    echo ""
    echo "[Service]"
    echo "Type=oneshot"
    echo "TimeoutStartSec=60"
    echo "Environment=PATH=$spath"
    echo "Environment=TOKEN_PACE_DIR=$TP_DIR"
    [[ -n ${CLAUDE_CONFIG_DIR:-} ]] && echo "Environment=CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
    [[ -n ${CODEX_HOME:-} ]]        && echo "Environment=CODEX_HOME=$CODEX_HOME"
    echo "ExecStart=/usr/bin/env bash $TICK --from timer"
  } > "$MASTER/$NAME.service"
  {
    echo "[Unit]"
    echo "Description=claude-token-pace: sample usage periodically"
    echo ""
    echo "[Timer]"
    echo "OnBootSec=1min"
    echo "OnUnitActiveSec=${n}min"
    echo ""
    echo "[Install]"
    echo "WantedBy=timers.target"
  } > "$MASTER/$NAME.timer"
  local spec env_pre
  if [[ $n -le 1 ]]; then spec="* * * * *"; else spec="*/$n * * * *"; fi
  env_pre="PATH=\"$spath\" TOKEN_PACE_DIR=\"$TP_DIR\""
  [[ -n ${CLAUDE_CONFIG_DIR:-} ]] && env_pre="$env_pre CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\""
  [[ -n ${CODEX_HOME:-} ]]        && env_pre="$env_pre CODEX_HOME=\"$CODEX_HOME\""
  printf '%s\n' "$spec $env_pre bash \"$TICK\" --from timer >/dev/null 2>&1 $TAG" > "$MASTER/cron.line"
  now > "$MASTER/installed_at"
}

deploy_systemd() {
  mkdir -p "$UNIT_DIR" || return 1
  cp "$MASTER/$NAME.service" "$MASTER/$NAME.timer" "$UNIT_DIR/" || return 1
  systemctl --user daemon-reload 2>/dev/null \
    && systemctl --user enable "$NAME.timer" >/dev/null 2>&1 \
    && systemctl --user restart "$NAME.timer" >/dev/null 2>&1
}

deploy_cron() {
  local cur
  cur="$(read_crontab)" || return 1
  { printf '%s\n' "$cur" | drop_own_cron | sed '/^$/d'; cat "$MASTER/cron.line"; } | crontab - 2>/dev/null
}

cmd_setup() {
  local sched="none" ival
  if [[ -n ${TOKEN_PACE_NO_SCHEDULER:-} ]]; then
    local removed; removed="$(cmd_remove)"
    echo "  定期実行: TOKEN_PACE_NO_SCHEDULER が設定されているため設置しません${removed:+（既存の登録 $removed を外しました）}"
    printf '%s\n' none > "$TP_DIR/.scheduler"
    return 0
  fi
  make_master
  ival="$(<"$MASTER/interval")min"
  if systemd_usable; then
    if deploy_systemd; then
      sched="systemd"
      remove_cron >/dev/null 2>&1 || true     # 以前 cron で入れていたら二重に動かさない
      echo "  定期実行: systemd の user timer（$ival おき）"
      # ログアウト中も動かすための linger（権限が無ければ付かない。致命的ではない）
      if loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1; then
        : > "$TP_DIR/.linger"
      fi
    else
      rm -f "$UNIT_DIR/$NAME.service" "$UNIT_DIR/$NAME.timer"
      echo "  定期実行: systemd への登録に失敗したため設置しませんでした" >&2
    fi
  elif command -v crontab >/dev/null 2>&1; then
    if deploy_cron; then
      sched="cron"
      remove_systemd >/dev/null 2>&1 || true  # 以前 systemd で入れていたら二重に動かさない
      echo "  定期実行: cron（$(cut -d' ' -f1-5 "$MASTER/cron.line")）"
    else
      echo "  定期実行: cron への登録に失敗したため設置しませんでした" >&2
    fi
  else
    echo "  定期実行: systemd も cron も無いため設置できません。statusLine が表示されるときだけ記録されます" >&2
    echo "    $TICK を任意のスケジューラから数分おきに実行してください" >&2
  fi
  printf '%s\n' "$sched" > "$TP_DIR/.scheduler"
}

# ---- remove ----
# この設置先の systemd の登録を外す（外したら 0）
remove_systemd() {
  command -v systemctl >/dev/null 2>&1 && own_unit_file || return 1
  # 止めるのは、systemd が読み込んでいるユニットもこの設置先のものだと確かめられたときだけ
  local loaded=""
  own_loaded_unit && loaded=1
  [[ -n $loaded ]] && { systemctl --user disable --now "$NAME.timer" >/dev/null 2>&1 || true; }
  rm -f "$UNIT_DIR/$NAME.timer" "$UNIT_DIR/$NAME.service"
  [[ -n $loaded ]] && { systemctl --user daemon-reload >/dev/null 2>&1 || true; }
  return 0
}
# この設置先の cron 行を外す（外したら 0）
remove_cron() {
  command -v crontab >/dev/null 2>&1 || return 1
  local cur
  cur="$(read_crontab)" || return 1
  printf '%s\n' "$cur" | grep -F "$TAG" | mentions_tick || return 1
  printf '%s\n' "$cur" | drop_own_cron | sed '/^$/d' | crontab - 2>/dev/null
}
# 外したものを「systemd」「cron」「systemd+cron」の形で標準出力に返す
cmd_remove() {
  local removed=""
  remove_systemd && removed="systemd"
  remove_cron && removed="${removed:+$removed+}cron"
  printf '%s' "$removed"
}

# ---- check ----
REPAIR=""
PROBLEM=0
problem() { PROBLEM=1; echo "$*"; }

# 最後に timer から起動された時刻が古すぎないか。基準は「最後の起動」「設置」「最後の修理」の新しい方
timer_stale() {
  local n t f last=0 base
  n="$(cat "$MASTER/interval" 2>/dev/null)"; [[ $n =~ ^[0-9]+$ ]] || n=5
  for f in "$TP_DIR/.last_timer_tick" "$MASTER/installed_at" "$MASTER/repaired_at"; do
    t="$(cat "$f" 2>/dev/null)"
    [[ $t =~ ^[0-9]+$ ]] && (( t > last )) && last=$t
  done
  base=$(now)
  STALE_MIN=$(( (base - last) / 60 ))
  (( base - last > n * 60 * 3 + 120 ))
}

check_systemd() {
  if ! systemd_usable; then
    problem "systemd に接続できないため点検できません（直しません）"
    return
  fi
  if [[ ! -f $MASTER/$NAME.service || ! -f $MASTER/$NAME.timer ]]; then
    problem "設置内容の控え（${MASTER}）が無いため点検できません。install.sh を流し直してください"
    return
  fi
  # 別の設置先のユニットなら触らない
  if [[ -f $UNIT_DIR/$NAME.service ]] && ! own_unit_file; then
    problem "ユニットファイルが別の設置先を指しているため触りません（$UNIT_DIR/$NAME.service）"
    return
  fi
  if [[ "$(loaded_state)" == loaded ]] && ! own_loaded_unit; then
    problem "systemd が読み込んでいるユニットが別の設置先を指しているため触りません"
    return
  fi

  local restart="" f
  for f in "$NAME.service" "$NAME.timer"; do
    if ! cmp -s "$MASTER/$f" "$UNIT_DIR/$f"; then
      if [[ -f $UNIT_DIR/$f ]]; then problem "ユニット $f が設置時と違う"; else problem "ユニット $f が無い"; fi
      if [[ -n $REPAIR ]]; then
        mkdir -p "$UNIT_DIR" && cp "$MASTER/$f" "$UNIT_DIR/$f" && echo "  → $f を設置時の内容に戻した"
        restart=1
      fi
    fi
  done
  if [[ -n $restart ]]; then
    systemctl --user daemon-reload >/dev/null 2>&1
    # 書き戻したあと、systemd が読み込んだのがこの設置先のユニットかを確かめてから動かす
    if ! own_loaded_unit; then
      echo "  → systemd が読み込んだユニットがこの設置先のものではないため、起動はしません"
      return
    fi
  fi

  local en ac
  en="$(systemctl --user is-enabled "$NAME.timer" 2>/dev/null)"
  if [[ $en != enabled ]]; then
    problem "timer が有効になっていない（is-enabled=${en:-不明}）"
    if [[ -n $REPAIR ]] && systemctl --user enable "$NAME.timer" >/dev/null 2>&1; then
      echo "  → enable した"
    fi
  fi
  ac="$(systemctl --user is-active "$NAME.timer" 2>/dev/null)"
  if [[ $ac != active ]]; then
    problem "timer が動いていない（is-active=${ac:-不明}）"
    restart=1
  fi
  if timer_stale; then
    problem "timer から ${STALE_MIN} 分起動されていない"
    restart=1
  fi
  if [[ -n $REPAIR && -n $restart ]]; then
    if systemctl --user restart "$NAME.timer" >/dev/null 2>&1; then
      echo "  → timer を restart した"
    else
      echo "  → timer の restart に失敗した"
    fi
    now > "$MASTER/repaired_at"
  fi
}

check_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    problem "crontab コマンドが無いため点検できません"
    return
  fi
  if [[ ! -f $MASTER/cron.line ]]; then
    problem "設置内容の控え（$MASTER/cron.line）が無いため点検できません。install.sh を流し直してください"
    return
  fi
  local cur
  if ! cur="$(read_crontab)"; then
    problem "crontab が読めないため点検できません（直しません）"
    return
  fi
  if ! printf '%s\n' "$cur" | grep -F -x -q "$(<"$MASTER/cron.line")"; then
    problem "cron にこの設置先の行が無い、または設置時と違う"
    if [[ -n $REPAIR ]] && deploy_cron; then
      echo "  → cron の行を設置時の内容に戻した"
      now > "$MASTER/repaired_at"
    fi
  elif timer_stale; then
    # cron 自体が止まっているときは、ここからは直せない
    problem "cron から ${STALE_MIN} 分起動されていない（cron のサービスが動いているか確認してください）"
  fi
}

cmd_check() {
  [[ ${1:-} == --repair ]] && REPAIR=1
  local sched="none"
  [[ -r $TP_DIR/.scheduler ]] && sched=$(<"$TP_DIR/.scheduler")
  case "$sched" in
    systemd) check_systemd ;;
    cron)    check_cron ;;
    *)       return 0 ;;     # 未設置（TOKEN_PACE_NO_SCHEDULER など）は点検の対象外
  esac
  return "$PROBLEM"
}

case "${1:-}" in
  setup)  cmd_setup ;;
  remove) cmd_remove; echo ;;
  check)  shift; cmd_check "$@" ;;
  *) echo "usage: $0 setup | remove | check [--repair]" >&2; exit 64 ;;
esac
