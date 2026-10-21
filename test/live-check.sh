#!/usr/bin/env bash
# 実環境で記録が続いているかを確かめる（読み取り専用。何も変更しない）。
#
# 記録経路に触る変更をしたら、smoke test とは別に必ずこれを流す。smoke test は
# 一時 HOME の中で「正しく作れるか」を見るだけで、実環境の定期実行が動き続けて
# いるか（利用者が受け取る結果）は見ない。2026-10-20 に試験が本物の timer を止めた
# ときは、smoke が通ったまま 14.5 時間記録が欠測した。
#
# 見るもの:
#   1) .scheduler に応じて、systemd の timer が有効かつ動作中か / cron 行があるか
#      （どちらもこの設置先 $TOKEN_PACE_DIR の tick.sh を指していること）
#   2) tick.log・pace.jsonl・pace.json が N 分以内に更新されているか（既定 15 分）
#      pace.jsonl は 429 のバックオフ中なら古くても異常にしない
#
# 使い方: bash test/live-check.sh [N分]
# 終了コード: 0 = 動いている / 1 = 異常あり / 2 = 定期実行が未設置（.scheduler=none）
set -u
TP_DIR="${TOKEN_PACE_DIR:-$HOME/.claude/token-pace}"
MIN="${1:-15}"
[[ $MIN =~ ^[0-9]+$ ]] || { echo "N分は整数で指定してください: $MIN" >&2; exit 1; }
TICK="$TP_DIR/bin/tick.sh"
bad=0
okm()  { echo "OK   $*"; }
ngm()  { echo "NG   $*"; bad=1; }
note() { echo "注意 $*"; }

[[ -d $TP_DIR ]] || { echo "NG   設置先がありません: $TP_DIR"; exit 1; }
sched="(無し)"
[[ -r $TP_DIR/.scheduler ]] && sched=$(<"$TP_DIR/.scheduler")

case "$sched" in
  systemd)
    en="$(systemctl --user is-enabled claude-token-pace.timer 2>&1)"
    ac="$(systemctl --user is-active claude-token-pace.timer 2>&1)"
    ex="$(systemctl --user show -p ExecStart claude-token-pace.service 2>&1)"
    if [[ $en == enabled && $ac == active ]]; then
      okm "systemd timer: enabled / active"
    else
      ngm "systemd timer: is-enabled=$en is-active=$ac"
    fi
    if [[ $ex == *" $TICK "* || $ex == *" $TICK" ]]; then
      okm "timer が起動するのはこの設置先の tick.sh"
    else
      ngm "timer の起動先がこの設置先の tick.sh ではない: $ex"
    fi
    ;;
  cron)
    if crontab -l 2>/dev/null | grep -F -q "\"$TICK\""; then
      okm "cron: この設置先の tick.sh を呼ぶ行がある"
    else
      ngm "cron: この設置先の tick.sh を呼ぶ行が無い"
    fi
    ;;
  none)
    echo "--   定期実行は未設置です（.scheduler=none）"
    ;;
  *)
    ngm ".scheduler が読めない、または不明な値: $sched"
    ;;
esac

# 更新が N 分以内か（find -mmin は GNU と BSD の両方で使える）
fresh() { [[ -f $1 ]] && [[ -n "$(find "$1" -maxdepth 0 -mmin "-$MIN" 2>/dev/null)" ]]; }

if fresh "$TP_DIR/tick.log"; then
  okm "tick.log: ${MIN} 分以内に更新（最終行: $(tail -n 1 "$TP_DIR/tick.log")）"
else
  ngm "tick.log: ${MIN} 分以上更新されていない（定期実行が動いていない）"
fi

src="$(tail -n 1 "$TP_DIR/pace.jsonl" 2>/dev/null | sed -n 's/.*"src": *"\([^"]*\)".*/\1/p')"
if fresh "$TP_DIR/pace.jsonl"; then
  okm "pace.jsonl: ${MIN} 分以内に記録（src=${src:-なし}）"
else
  now=$(date +%s)
  until=0
  [[ -r $TP_DIR/.usage_backoff ]] && until=$(<"$TP_DIR/.usage_backoff")
  if [[ $until =~ ^[0-9]+$ ]] && (( until > now )); then
    note "pace.jsonl: ${MIN} 分以上記録が無いが、429 のバックオフ中（あと $(( (until - now) / 60 )) 分）"
  else
    ngm "pace.jsonl: ${MIN} 分以上記録が無い（src=${src:-なし}）"
  fi
fi

if fresh "$TP_DIR/pace.json"; then
  okm "pace.json: ${MIN} 分以内に再生成"
else
  ngm "pace.json: ${MIN} 分以上再生成されていない（グラフが更新されない）"
fi

if (( bad )); then exit 1; fi
[[ $sched == none ]] && exit 2
exit 0
