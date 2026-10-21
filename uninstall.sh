#!/usr/bin/env bash
# claude-token-pace アンインストーラ。
#   1) statusLine を元に戻す（.orig_statusline.json から）
#   2) /tpw コマンドを削除
#   3) 定期実行（systemd の user timer / cron）を解除
#   4) 稼働中のローカルサーバを停止
# データ($TOKEN_PACE_DIR)は残す（完全削除は最後の案内どおり手動で）。
set -u

TP_DIR="${TOKEN_PACE_DIR:-$HOME/.claude/token-pace}"
SETTINGS="$HOME/.claude/settings.json"
CMD="$HOME/.claude/commands/tpw.md"

# 1) statusLine 復元（ラッパーが設定に残っている場合だけ）
WRAPPER="$TP_DIR/bin/statusline-wrapper.sh"
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1 \
   && [[ "$(jq -r '.statusLine.command // ""' "$SETTINGS")" == "$WRAPPER" ]]; then
  if [[ -f "$TP_DIR/.orig_statusline.json" ]]; then
    orig=$(cat "$TP_DIR/.orig_statusline.json")
    tmp="$SETTINGS.tp.tmp.$$"
    ts=$(date +%s 2>/dev/null || echo now)
    cp "$SETTINGS" "$SETTINGS.tokenpace-bak.$ts" 2>/dev/null
    if [[ -z "$orig" || "$orig" == "null" ]]; then
      jq 'del(.statusLine)' "$SETTINGS" > "$tmp"        # 元々 statusLine 無し
    else
      jq --argjson o "$orig" '.statusLine = $o' "$SETTINGS" > "$tmp"
    fi
    if [[ -s "$tmp" ]] && jq -e . "$tmp" >/dev/null 2>&1; then   # 空ファイルも jq empty は通るので -s と -e で見る
      mv "$tmp" "$SETTINGS"
      echo "statusLine を元に戻しました（backup: $SETTINGS.tokenpace-bak.${ts}）"
    else
      rm -f "$tmp"
      echo "statusLine 復元に失敗（JSON不正）。手動で確認してください。" >&2
    fi
  else
    echo "元の statusLine 情報が無いため settings.json は変更しません" >&2
  fi
fi

# 2) コマンド削除
[[ -f "$CMD" ]] && rm -f "$CMD" && echo "コマンド $CMD を削除しました"

# 3) 定期実行の解除。systemctl --user も crontab も $HOME を見ないので、
#    scheduler.sh がこの設置先（$TP_DIR）を指す登録であることを確かめてから外す
#    （別の設置先の定期実行を止めないため）。
if [[ -f "$TP_DIR/bin/scheduler.sh" ]]; then
  removed="$(TOKEN_PACE_DIR="$TP_DIR" bash "$TP_DIR/bin/scheduler.sh" remove)"
  [[ $removed == *systemd* ]] && echo "定期実行(systemd timer)を解除しました"
  [[ $removed == *cron* ]]    && echo "定期実行(cron)を解除しました"
fi

# 4) サーバ停止
if [[ -r "$TP_DIR/.web_server" ]]; then
  read -r spid _ < "$TP_DIR/.web_server" 2>/dev/null || true
  if [[ -n "${spid:-}" ]] && kill "$spid" 2>/dev/null; then
    echo "ローカルサーバ(PID $spid)を停止しました"
  fi
fi

echo "データは $TP_DIR に残しています。完全に消すには: rm -rf \"$TP_DIR\""
