#!/usr/bin/env bash
# claude-token-pace インストール一気通貫スモークテスト（CI / ローカル共用）。
#
# 隔離した一時 HOME に対して以下を検証する。実環境(~/.claude)には一切触れない:
#   install → statusLine ラッパー化 → 記録(tick.sh: 定期実行と statusLine の 2 契機)
#         → 定期実行の設置・点検・修理（systemctl / crontab は差し替え）→ pace.json 生成
#         → serve.sh で / と /pace.json を配信 → 冪等性 → uninstall で復元
# 最後に、実ユーザーの systemd timer・ユニットファイル・crontab が試験の前後で変わっていないことを検査する。
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

fail() { echo "❌ FAIL: $*" >&2; exit 1; }
ok()   { echo "✅ $*"; }

# --- uid に属する資源の不変検査 ---
# systemd の user manager と crontab は uid 単位で、HOME を差し替えても隔離できない。
# 試験がそれらに触っていないことを「主張」ではなく「検査」で確かめるため、
# HOME を書き換える前に実ユーザー側の状態を写し取り、終了時に変わっていないかを見る。
# （2026-10-20、試験が本物の timer を止めて 14.5 時間記録が欠測した事故の再発防止）
# service の is-active は数秒おきに activating/inactive を行き来するので対象にしない。
REAL_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
uid_snapshot() {
  local out f
  out="$(systemctl --user is-enabled claude-token-pace.timer 2>&1)" || true
  printf 'timer is-enabled: %s\n' "$out"
  out="$(systemctl --user is-active claude-token-pace.timer 2>&1)" || true
  printf 'timer is-active: %s\n' "$out"
  for f in claude-token-pace.timer claude-token-pace.service; do
    if [ -f "$REAL_UNIT_DIR/$f" ]; then
      printf '%s: %s\n' "$f" "$(cksum < "$REAL_UNIT_DIR/$f")"
    else
      printf '%s: (無し)\n' "$f"
    fi
  done
  out="$(crontab -l 2>&1 | cksum)" || true
  printf 'crontab -l: %s\n' "$out"
}
UID_BEFORE="$(uid_snapshot)"
UID_CHECKED=""
verify_uid_resources() {
  local now
  UID_CHECKED=1
  now="$(uid_snapshot)"
  if [ "$now" != "$UID_BEFORE" ]; then
    echo "❌ FAIL: 試験が実ユーザーの systemd / crontab を変えた（HOME では隔離できない資源）" >&2
    echo "--- 試験前" >&2; printf '%s\n' "$UID_BEFORE" >&2
    echo "--- 試験後" >&2; printf '%s\n' "$now" >&2
    return 1
  fi
}

cleanup() {
  # 途中で落ちた実行でも、実ユーザーの資源に触っていないかは必ず見る
  if [ -z "$UID_CHECKED" ]; then verify_uid_resources || true; fi
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
# 定期実行(systemd の user timer / cron)は実ユーザーの systemd・crontab を触るので設置しない。
# あわせて XDG_CONFIG_HOME も一時 HOME に向け、実ユーザーのユニットを見に行かせない。
export TOKEN_PACE_NO_SCHEDULER=1
export XDG_CONFIG_HOME="$TMPHOME/.config"
TP_DIR="$HOME/.claude/token-pace"
SETTINGS="$HOME/.claude/settings.json"
WRAPPER="$TP_DIR/bin/statusline-wrapper.sh"

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

# 使用量 API へは実通信しない。応答はローカルの canned JSON を file:// で読ませる
# （リセット時刻は now 相対にして、記録が窓内に入るようにする）
UJSON="$TMPHOME/usage.json"
python3 - "$UJSON" <<'PY'
import datetime, json, sys, time
now = int(time.time())
def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"five_hour": {"utilization": 62, "resets_at": iso(now + 3600)},
           "seven_day": {"utilization": 41, "resets_at": iso(now + 3 * 86400)}},
          open(sys.argv[1], "w"))
PY
export TOKEN_PACE_USAGE_URL="file://$UJSON"

# 既存 statusLine を仕込む（ラッパーがこれを転送することを検証するため）
jq -n '{statusLine:{type:"command",command:"echo ORIG-STATUSLINE-OK"}}' > "$SETTINGS"

if [ "$MODE" = "bootstrap" ]; then
  echo "== smoke: HOME=$HOME  mode=bootstrap  repo=$BOOT_REPO  ref=$BOOT_REF =="
else
  echo "== smoke: HOME=$HOME  mode=direct =="
fi

# 0) 版表記の一致: VERSION と README 冒頭の版表記がずれると、読者はどの版の README か
#    判断できない。release-guard.yml はタグ push 時に VERSION とタグ名しか見ないので、
#    README とのずれを検出できるのはここだけ。
ver="$(tr -d '[:space:]' < "$REPO/VERSION")"
[ -n "$ver" ] || fail "VERSION ファイルが空"
for rd in README.md README.en.md; do
  [ -f "$REPO/$rd" ] || fail "$rd が無い"
  # 冒頭 10 行から最初の **x.y.z** を取る（本文の太字に数字が来ても拾わない形）
  shown="$(sed -n '1,10p' "$REPO/$rd" \
           | sed -n 's/.*\*\*\([0-9][0-9.]*\)\*\*.*/\1/p' | head -1)"
  [ -n "$shown" ] || fail "$rd の冒頭に版表記（**x.y.z**）が見つからない"
  [ "$shown" = "$ver" ] \
    || fail "$rd の版表記 ($shown) が VERSION ($ver) と一致しない。どちらかを揃えること"
done
ok "版表記の一致: VERSION=$ver と README.md / README.en.md の冒頭が一致"

# 1) install（direct=install.sh / bootstrap=curl ワンライナー経路）
do_install || fail "インストール($MODE) が非ゼロ終了"
[ -x "$TP_DIR/bin/serve.sh" ]    || fail "serve.sh 未配置"
[ -x "$TP_DIR/bin/usage-fetch.py" ] || fail "usage-fetch.py 未配置"
[ -x "$TP_DIR/bin/tick.sh" ]     || fail "tick.sh 未配置"
[ ! -e "$TP_DIR/bin/sampler.sh" ] || fail "statusLine 用の sampler.sh が残っている"
[ -x "$TP_DIR/bin/pace-json.py" ]|| fail "pace-json.py 未配置"
[ -f "$TP_DIR/bin/serve-http.py" ]|| fail "serve-http.py 未配置"
[ -x "$TP_DIR/bin/credits-fetch.py" ] || fail "credits-fetch.py 未配置"
[ -x "$TP_DIR/bin/codex-scan.py" ] || fail "codex-scan.py 未配置"
[ -f "$TP_DIR/index.html" ]      || fail "index.html 未配置"
[ -f "$HOME/.claude/commands/tpw.md" ] || fail "/tpw コマンド未設置"
[ -x "$TP_DIR/bin/scheduler.sh" ] || fail "scheduler.sh 未配置"
[ -x "$WRAPPER" ] || fail "statusLine ラッパーが作られない"
got_sl="$(jq -r '.statusLine.command' "$SETTINGS")"
[ "$got_sl" = "$WRAPPER" ] || fail "statusLine がラッパーを指していない (got: $got_sl)"
[ "$(cat "$TP_DIR/.orig_statusline")" = "echo ORIG-STATUSLINE-OK" ] || fail "元の statusLine が保存されていない"
[ "$(cat "$TP_DIR/.scheduler")" = "none" ] || fail "TOKEN_PACE_NO_SCHEDULER が効いていない"
! grep -q 'sampler' "$WRAPPER" || fail "ラッパーが旧版の sampler.sh を呼んでいる"
ok "install($MODE): ファイル配置・/tpw 設置・statusLine をラッパーに差し替え（元は保存）"

# 2) 記録は定期実行の経路だけで行う（tick.sh = timer / cron から呼ばれる入口）
now_t="$(date +%s)"
printf '%s' "$now_t" > "$TP_DIR/.last_credits"   # 月次と Codex はこのケースの対象外
printf '%s' "$now_t" > "$TP_DIR/.last_codex"
bash "$TP_DIR/bin/tick.sh" || fail "tick.sh が非ゼロ終了"
[ -s "$TP_DIR/pace.jsonl" ] || fail "tick.sh が pace.jsonl に記録しない"
tail -1 "$TP_DIR/pace.jsonl" | jq -e '.src=="api" and has("ts") and has("h5") and has("d7")' >/dev/null \
  || fail "記録行に必要フィールドが無い"
rows="$(wc -l < "$TP_DIR/pace.jsonl" 2>/dev/null | tr -d '[:space:]')"
grep -q ' usage 記録した（契機=manual）$' "$TP_DIR/tick.log" || fail "tick.log に実行の記録が残らない（切り分けできない）"
ok "定期実行の入口 tick.sh が API 応答から記録し、tick.log に結果を残す (pace.jsonl=$rows 行)"

# 3a) 0.3.0 以前からの更新: statusLine がすでに（sampler.sh を呼ぶ）旧ラッパーを指していても、
#     ラッパーの中身は新しくなり、保存済みの元の statusLine は上書きされない
printf '#!/usr/bin/env bash\nbash "%s/bin/sampler.sh" &\n' "$TP_DIR" > "$WRAPPER"
do_install || fail "旧ラッパーからの更新が失敗"
! grep -q 'sampler' "$WRAPPER" || fail "旧ラッパーの中身が置き換わらない"
[ "$(jq -r '.statusLine.command' "$SETTINGS")" = "$WRAPPER" ] || fail "旧ラッパーからの更新で statusLine が変わった"
[ "$(cat "$TP_DIR/.orig_statusline")" = "echo ORIG-STATUSLINE-OK" ] || fail "旧ラッパーからの更新で元の statusLine を上書きした"
ok "0.3.0 以前からの更新: 旧ラッパーを置き換え、元の statusLine は保持"

# 3) statusLine の契機: ラッパーは元の statusLine の出力をそのまま返し、
#    記録（tick.sh --from statusline）を切り離して蹴る。1 分以内の再呼び出しでは蹴らない
rm -f "$TP_DIR/.last_usage" "$TP_DIR/.last_statusline"
printf '%s' "$now_t" > "$TP_DIR/.last_plot"      # このケースでは usage の記録だけを見る
rows0="$(wc -l < "$TP_DIR/pace.jsonl" | tr -d '[:space:]')"
sl_out="$(echo '{"session_id":"smoke"}' | bash "$WRAPPER")"
[ "$sl_out" = "ORIG-STATUSLINE-OK" ] || fail "ラッパーが元の statusLine の出力を返さない (got: $sl_out)"
i=0
until grep -q ' usage 記録した（契機=statusline）$' "$TP_DIR/tick.log"; do
  i=$((i + 1)); [ "$i" -le 30 ] || fail "statusLine の契機で tick.sh が記録しない"
  sleep 0.5
done
rows1="$(wc -l < "$TP_DIR/pace.jsonl" | tr -d '[:space:]')"
[ "$rows1" -eq $((rows0 + 1)) ] || fail "statusLine の契機で 1 行記録されない ($rows0 → $rows1)"
tail -1 "$TP_DIR/pace.jsonl" | jq -e '.src=="api"' >/dev/null || fail "statusLine の契機でも API から取得すること"
stamp1="$(cat "$TP_DIR/.last_statusline")"
echo '{}' | bash "$WRAPPER" >/dev/null
[ "$(cat "$TP_DIR/.last_statusline")" = "$stamp1" ] || fail "1 分以内の statusLine で再び tick を蹴った"
ok "statusLine の契機: 元の出力を返し、tick.sh を蹴って API から記録・1 分以内は蹴らない"

# 3k) macOS の Keychain 読み出し: security を差し替えて、ファイルが無くても認証情報を読めること、
#     ファイルがあればそちらが優先されること、security が失敗したらトークン無しとして扱うことを見る
KCDIR="$HOME/kc"; mkdir -p "$KCDIR/bin" "$KCDIR/empty" "$KCDIR/withfile"
cat > "$KCDIR/bin/security" <<'KCEOF'
#!/bin/sh
[ "$1" = "find-generic-password" ] || exit 1
case "$3" in
  "Claude Code-credentials") echo '{"claudeAiOauth":{"accessToken":"KC-TOKEN","expiresAt":99999999999999}}'; exit 0 ;;
  *) exit 44 ;;
esac
KCEOF
printf '#!/bin/sh\nexit 44\n' > "$KCDIR/bin/security-fail"
chmod +x "$KCDIR/bin/security" "$KCDIR/bin/security-fail"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"FILE-TOKEN","expiresAt":99999999999999}}' \
  > "$KCDIR/withfile/.credentials.json"
read_token() {   # read_token <スクリプト> <security の実体> <CLAUDE_CONFIG_DIR>
  TOKEN_PACE_SECURITY_BIN="$2" CLAUDE_CONFIG_DIR="$3" python3 - "$TP_DIR/bin/$1" <<'KCPY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    print(m.access_token())
except TypeError:            # credits-fetch.py は now を取る
    print(m.access_token(time.time()))
KCPY
}
for f in usage-fetch.py credits-fetch.py; do
  got="$(read_token "$f" "$KCDIR/bin/security" "$KCDIR/empty")"
  [ "$got" = "KC-TOKEN" ] || fail "$f が Keychain から読めない (got: $got)"
  got="$(read_token "$f" "$KCDIR/bin/security" "$KCDIR/withfile")"
  [ "$got" = "FILE-TOKEN" ] || fail "$f がファイルより Keychain を優先した (got: $got)"
  got="$(read_token "$f" "$KCDIR/bin/security-fail" "$KCDIR/empty")"
  [ "$got" = "None" ] || fail "$f が Keychain 読み出し失敗を None にしない (got: $got)"
done
ok "macOS の Keychain: ファイルが無ければ security から読み、ファイルがあれば優先、失敗はトークン無し"

# 3s) スケジューラの設置: systemctl / loginctl / crontab を差し替えて、
#     生成されるユニット本文と cron 行だけを検証する（実ユーザーの systemd・crontab は触らない）。
#     systemctl の差し替えは状態を持ち（enable/restart/disable を覚える）、show が返す
#     ExecStart は差し替え先のユニットファイルの中身から作る（loaded_exec があればそちらを返す）
STUB="$HOME/stubbin"; SD="$HOME/xdg"; CALLS="$HOME/sched-calls.txt"; CRONF="$HOME/crontab.txt"
SDST="$HOME/sdstate"
mkdir -p "$STUB" "$SD" "$SDST"; : > "$CALLS"; : > "$CRONF"
cat > "$STUB/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$CALLS"
SVCF="$SD/systemd/user/claude-token-pace.service"
case "\$*" in
  *show-environment*) [ -n "\${SYSTEMD_STUB_FAIL:-}" ] && exit 1; exit 0 ;;
  *"show -p ExecStart"*)
    if [ -f "$SDST/loaded_exec" ]; then cat "$SDST/loaded_exec"
    elif [ -f "\$SVCF" ]; then sed -n 's|^ExecStart=\(.*\)|ExecStart={ path=/usr/bin/env ; argv[]=\1 ; ignore_errors=no }|p' "\$SVCF"; fi
    exit 0 ;;
  *"show -p LoadState"*) if [ -f "\$SVCF" ] || [ -f "$SDST/loaded_exec" ]; then echo loaded; else echo not-found; fi; exit 0 ;;
  *is-enabled*) v=\$(cat "$SDST/enabled" 2>/dev/null || echo disabled); echo "\$v"; [ "\$v" = enabled ]; exit \$? ;;
  *is-active*)  v=\$(cat "$SDST/active" 2>/dev/null || echo inactive); echo "\$v"; [ "\$v" = active ]; exit \$? ;;
  *"disable --now"*) echo disabled > "$SDST/enabled"; echo inactive > "$SDST/active" ;;
  *" enable "*) echo enabled > "$SDST/enabled" ;;
  *restart*) echo active > "$SDST/active" ;;
esac
exit 0
EOF
cat > "$STUB/loginctl" <<EOF
#!/bin/sh
echo "loginctl \$*" >> "$CALLS"
exit 0
EOF
cat > "$STUB/crontab" <<EOF
#!/bin/sh
echo "crontab \$*" >> "$CALLS"
if [ "\$1" = "-l" ]; then
  [ -n "\${CRONTAB_STUB_FAIL:-}" ] && { echo "crontab: cannot connect" >&2; exit 1; }
  cat "$CRONF"; exit 0
fi
cat > "$CRONF"
exit 0
EOF
chmod +x "$STUB/systemctl" "$STUB/loginctl" "$STUB/crontab"
PY_DIR="$(dirname "$(command -v python3)")"
TICK="$TP_DIR/bin/tick.sh"
UNIT="$SD/systemd/user/claude-token-pace.timer"; SVC="$SD/systemd/user/claude-token-pace.service"
# スタブ環境で動かす（定期実行を設置させるため TOKEN_PACE_NO_SCHEDULER は外す）
stubenv() { env -u TOKEN_PACE_NO_SCHEDULER PATH="$STUB:$PATH" XDG_CONFIG_HOME="$SD" "$@"; }
sched() { stubenv bash "$TP_DIR/bin/scheduler.sh" "$@"; }
# 状態を変える systemctl / crontab の呼び出しがあったか（CALLS を空にしてから使う）
mutated() { grep -E 'systemctl --user (enable|disable|restart|start|stop|daemon-reload)|^crontab -$' "$CALLS"; }

# 3s-1) systemd 経路
stubenv bash "$REPO/install.sh" >/dev/null || fail "スタブ環境の install(systemd) が失敗"
if [ ! -f "$UNIT" ] || [ ! -f "$SVC" ]; then fail "systemd のユニットが生成されない"; fi
grep -q '^OnUnitActiveSec=5min$' "$UNIT" || fail "timer の間隔が 5min でない: $(grep -c . "$UNIT") 行"
! grep -q '^Persistent=' "$UNIT" || fail "monotonic timer に効かない Persistent= が残っている"
grep -q "^Environment=TOKEN_PACE_DIR=$TP_DIR\$" "$SVC" || fail "service に TOKEN_PACE_DIR が無い"
grep -q "^ExecStart=.* $TICK --from timer\$" "$SVC" || fail "service の ExecStart が tick.sh --from timer でない"
grep -q "^Environment=PATH=.*$PY_DIR" "$SVC" || fail "service の PATH に python3 の場所が無い"
grep -q 'systemctl --user restart claude-token-pace.timer' "$CALLS" \
  || fail "間隔の変更が効くよう timer を restart していない"
[ "$(cat "$TP_DIR/.scheduler")" = "systemd" ] || fail ".scheduler が systemd でない"
cmp -s "$SVC" "$TP_DIR/sched/claude-token-pace.service" || fail "設置内容の控えがユニットと一致しない"

# 3s-2) 間隔の指定: 分は通る / 分以外は既定 5min に落として cron の分指定を壊さない
stubenv TOKEN_PACE_INTERVAL=10min bash "$REPO/install.sh" >/dev/null || fail "間隔 10min の install が失敗"
grep -q '^OnUnitActiveSec=10min$' "$UNIT" || fail "TOKEN_PACE_INTERVAL=10min が反映されない"
stubenv TOKEN_PACE_INTERVAL=1h bash "$REPO/install.sh" >/dev/null 2>&1 || fail "間隔 1h の install が失敗"
grep -q '^OnUnitActiveSec=5min$' "$UNIT" || fail "分以外の指定が既定 5min に落ちない（cron の分指定が壊れる）"

# 3h) 点検と修理（statusLine の契機で tick.sh が呼ぶ scheduler.sh check --repair）
# 3h-1) 正常なら何も変えない
: > "$CALLS"
sched check --repair >/dev/null || fail "正常な設置を異常と判定した"
! mutated >/dev/null || fail "正常なのに systemd / crontab を変更した: $(mutated | head -1)"
# 3h-2) --repair なしでは、異常があっても何も変えない
echo disabled > "$SDST/enabled"; echo inactive > "$SDST/active"; : > "$CALLS"
if sched check >/dev/null; then fail "止まった timer を正常と判定した"; fi
! mutated >/dev/null || fail "--repair なしで変更した: $(mutated | head -1)"
# 3h-3) --repair で enable と restart をする
out="$(sched check --repair)" && fail "修理した回の終了コードが 0（異常があったことが伝わらない）"
[ "$(cat "$SDST/enabled")/$(cat "$SDST/active")" = "enabled/active" ] || fail "修理後も timer が有効・動作中でない: $out"
sched check >/dev/null || fail "修理後の点検が正常にならない"
# 3h-4) ユニットファイルが消えていたら控えから戻して daemon-reload する
rm -f "$UNIT"; : > "$CALLS"
sched check --repair >/dev/null && fail "ユニットが無いのを正常と判定した"
cmp -s "$UNIT" "$TP_DIR/sched/claude-token-pace.timer" || fail "消えたユニットを控えから戻さない"
grep -q 'systemctl --user daemon-reload' "$CALLS" || fail "ユニットを戻したあと daemon-reload しない"
# 3h-5) timer から長く起動されていなければ restart する（設置・修理の直後は待つ）
printf '%s' "$((now_t - 7200))" > "$TP_DIR/.last_timer_tick"
printf '%s' "$((now_t - 7200))" > "$TP_DIR/sched/installed_at"
rm -f "$TP_DIR/sched/repaired_at"; : > "$CALLS"
out="$(sched check --repair)" && fail "timer が 2 時間起動されていないのを正常と判定した"
case "$out" in *"起動されていない"*) : ;; *) fail "起動されていないことを出力しない: $out" ;; esac
grep -q 'systemctl --user restart claude-token-pace.timer' "$CALLS" || fail "起動されていない timer を restart しない"
sched check >/dev/null || fail "restart の直後にまた異常と判定した（修理を繰り返してしまう）"
# 3h-6) ユニットファイルが別の設置先を指していたら、異常でも触らない
cp "$SVC" "$HOME/svc.keep"
sed 's|^ExecStart=.*|ExecStart=/usr/bin/env bash /somewhere/else/bin/tick.sh --from timer|' "$HOME/svc.keep" > "$SVC"
echo disabled > "$SDST/enabled"; : > "$CALLS"
out="$(sched check --repair)" && fail "別の設置先のユニットを正常と判定した"
! mutated >/dev/null || fail "別の設置先のユニットを変更した: $(mutated | head -1)"
grep -q '/somewhere/else/' "$SVC" || fail "別の設置先のユニットファイルを書き換えた"
#      読み込み済みのユニットがこちらを指していても、ファイルが別の設置先なら書き換えない
printf 'ExecStart={ path=/usr/bin/env ; argv[]=/usr/bin/env bash %s --from timer ; }\n' "$TICK" > "$SDST/loaded_exec"
: > "$CALLS"
sched check --repair >/dev/null && fail "別の設置先のユニットファイルを正常と判定した"
! mutated >/dev/null || fail "別の設置先のユニットファイルがあるのに変更した: $(mutated | head -1)"
grep -q '/somewhere/else/' "$SVC" || fail "別の設置先のユニットファイルを書き換えた（読み込み済みはこちら）"
rm -f "$SDST/loaded_exec"
# 3h-7) systemd が読み込んでいるユニットが別の設置先なら触らない（ファイルだけでは所有を決めない）
cp "$HOME/svc.keep" "$SVC"
printf 'ExecStart={ path=/usr/bin/env ; argv[]=/usr/bin/env bash /somewhere/else/bin/tick.sh ; }\n' > "$SDST/loaded_exec"
rm -f "$UNIT"; : > "$CALLS"
sched check --repair >/dev/null && fail "読み込み済みのユニットが別の設置先なのを正常と判定した"
! mutated >/dev/null || fail "別の設置先が読み込まれているのに変更した: $(mutated | head -1)"
rm -f "$SDST/loaded_exec"; cp "$TP_DIR/sched/claude-token-pace.timer" "$UNIT"; echo enabled > "$SDST/enabled"
# 3h-8) statusLine の契機の tick.sh が点検・修理し、結果を tick.log に残す（10 分に 1 回まで）
echo inactive > "$SDST/active"; rm -f "$TP_DIR/.last_sched_check"
stubenv bash "$TICK" --from statusline || fail "tick.sh --from statusline が失敗"
[ "$(cat "$SDST/active")" = "active" ] || fail "statusLine の契機で止まった timer を直さない"
grep -q ' scheduler .*is-active=inactive' "$TP_DIR/tick.log" || fail "点検の結果が tick.log に残らない"
echo inactive > "$SDST/active"
stubenv bash "$TICK" --from statusline || fail "tick.sh --from statusline（2 回目）が失敗"
[ "$(cat "$SDST/active")" = "inactive" ] || fail "10 分以内に再び点検した（statusLine ごとに systemctl を叩く）"
echo active > "$SDST/active"
# 3h-9) timer の契機では起動時刻を残す（点検が「timer が動いている」と判断する根拠）
rm -f "$TP_DIR/.last_timer_tick"
stubenv bash "$TICK" --from timer || fail "tick.sh --from timer が失敗"
[ -s "$TP_DIR/.last_timer_tick" ] || fail "timer の契機で起動時刻を残さない"
# 3h-10) 未設置（.scheduler=none）なら点検しない
printf 'none\n' > "$TP_DIR/.scheduler"; : > "$CALLS"
sched check --repair >/dev/null || fail "未設置を異常と判定した"
[ ! -s "$CALLS" ] || fail "未設置なのに systemctl / crontab を呼んだ: $(head -1 "$CALLS")"
printf 'systemd\n' > "$TP_DIR/.scheduler"

# 3s-3) cron 経路（systemd が使えない環境）。以前 systemd で入れた自分の登録は外す
stubenv SYSTEMD_STUB_FAIL=1 bash "$REPO/install.sh" >/dev/null || fail "スタブ環境の install(cron) が失敗"
[ "$(cat "$TP_DIR/.scheduler")" = "cron" ] || fail ".scheduler が cron でない"
cronline="$(grep '# claude-token-pace$' "$CRONF" || true)"
case "$cronline" in
  "*/5 * * * * PATH="*"TOKEN_PACE_DIR=\"$TP_DIR\" bash \"$TICK\" --from timer >/dev/null 2>&1 # claude-token-pace") : ;;
  *) fail "cron 行が不正: $cronline" ;;
esac
case "$cronline" in *"PATH=\""*"$PY_DIR"*) : ;; *) fail "cron 行の PATH に python3 の場所が無い: $cronline" ;; esac
[ ! -f "$SVC" ] || fail "cron に切り替えたのに systemd のユニットが残っている（二重に動く）"
# 3c) cron の点検と修理: 自分の行が消えていたら戻す。別の設置先の行は残す。読めなければ書かない
other="*/5 * * * * bash \"/somewhere/else/bin/tick.sh\" # claude-token-pace"
printf '%s\n%s\n' "MAILTO=\"\"" "$other" > "$CRONF"
sched check --repair >/dev/null && fail "cron 行が無いのを正常と判定した"
grep -q -F -x "$cronline" "$CRONF" || fail "消えた cron 行を戻さない"
grep -q -F -x "$other" "$CRONF" || fail "別の設置先の cron 行を消した"
grep -q -F -x 'MAILTO=""' "$CRONF" || fail "利用者の crontab の行を消した"
sched check >/dev/null || fail "cron の修理後の点検が正常にならない"
grep -v -F -x "$cronline" "$CRONF" > "$CRONF.n"; mv "$CRONF.n" "$CRONF"; cp "$CRONF" "$HOME/cron.keep"; : > "$CALLS"
stubenv CRONTAB_STUB_FAIL=1 bash "$TP_DIR/bin/scheduler.sh" check --repair >/dev/null && fail "crontab が読めないのを正常と判定した"
! grep -q '^crontab -$' "$CALLS" || fail "crontab が読めないのに書き戻した（空で上書きしてしまう）"
cmp -s "$CRONF" "$HOME/cron.keep" || fail "crontab が読めないのに中身が変わった"

# 3s-4) 解除: uninstall がこの設置先の cron 行を消す（別の設置先の行は残す）
sched check --repair >/dev/null || true
PATH="$STUB:$PATH" XDG_CONFIG_HOME="$SD" bash "$TP_DIR/uninstall.sh" >/dev/null || fail "uninstall(cron) が失敗"
! grep -q -F "\"$TICK\"" "$CRONF" || fail "uninstall が cron 行を消さない"
grep -q -F -x "$other" "$CRONF" || fail "uninstall が別の設置先の cron 行を消した"

# 3s-5) TOKEN_PACE_NO_SCHEDULER=1 は、以前の自分の登録（timer と cron 行）を撤去してから none にする
stubenv bash "$REPO/install.sh" >/dev/null || fail "撤去試験の準備(systemd) が失敗"
printf '%s\n' "*/5 * * * * TOKEN_PACE_DIR=\"$TP_DIR\" bash \"$TICK\" >/dev/null 2>&1 # claude-token-pace" >> "$CRONF"
: > "$CALLS"
PATH="$STUB:$PATH" XDG_CONFIG_HOME="$SD" bash "$REPO/install.sh" >/dev/null || fail "NO_SCHEDULER の install が失敗"
[ "$(cat "$TP_DIR/.scheduler")" = "none" ] || fail ".scheduler が none でない"
! grep -q -F "\"$TICK\"" "$CRONF" || fail "NO_SCHEDULER の install が既存の cron 行を残した"
grep -q -F -x "$other" "$CRONF" || fail "NO_SCHEDULER の install が別の設置先の cron 行を消した"
grep -q 'systemctl --user disable --now claude-token-pace.timer' "$CALLS" \
  || fail "NO_SCHEDULER の install が既存の timer を無効化していない"
[ ! -f "$UNIT" ] || fail "NO_SCHEDULER の install がユニットを残した"
# 3s-6) 別の設置先を指す登録は触らない（NO_SCHEDULER の撤去が実環境の timer を止めないための歯止め）
: > "$CALLS"
mkdir -p "$SD/systemd/user"
printf 'ExecStart=/usr/bin/env bash /somewhere/else/bin/tick.sh\n' > "$SVC"
printf '[Timer]\nOnUnitActiveSec=5min\n' > "$UNIT"
PATH="$STUB:$PATH" XDG_CONFIG_HOME="$SD" bash "$REPO/install.sh" >/dev/null \
  || fail "別の設置先が登録されている状態の install が失敗"
! grep -q 'systemctl --user disable' "$CALLS" \
  || fail "別の設置先を指す timer を止めた（実環境の定期実行を止めてしまう）"
[ -f "$SVC" ] || fail "別の設置先のユニットを消した"
rm -f "$SVC" "$UNIT"
ok "スケジューラ: ユニット/cron 行の中身・間隔・点検と修理（timer 停止・ユニット消失・起動途絶・cron 行消失）・解除・NO_SCHEDULER での撤去・別設置先には触らない"

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

# 5o) 古い窓のスナップショット回帰: h5r が観測時点より未来でも、いったん観測した h5r より
#     古い窓を報告する行は別の（古い）窓のスナップショット。_stale では弾けないので
#     mark_old_window が印を付ける。実測（2026-10-20 12:51:43）では h5=0/d7=100 の 1 行が
#     7d を 9% から 100% へ跳ねさせた。その行が除外されることを検証する。
ODIR="$HOME/oldwin-test"
mkdir -p "$ODIR"
python3 - "$ODIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
h5r_cur = now + 3600          # いま観測している 5h 窓
h5r_prev = now + 600          # それより古い窓（ただし観測時点より未来なので _stale は弾けない）
d7r = now + 3 * 86400         # 7d 窓は現窓と一致する（ここがスパイクの原因）
d7 = [5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9, 10, 10, 10]
h5 = [40, 42, 45, 48, 50, 52, 55, 58, 60, 62, 65, 68, 70, 72]
n = len(d7)
rows = [{"ts": now - (n - i) * 60, "h5": h5[i], "h5r": h5r_cur,
         "d7": d7[i], "d7r": d7r, "sid": "fresh"} for i in range(n)]
# 古い窓のスナップショット: h5=0 / d7=100、h5r は前の窓（未来だが後退している）
rows.append({"ts": now - (n // 2) * 60, "h5": 0, "h5r": h5r_prev,
             "d7": 100, "d7r": d7r, "sid": "oldwin"})
rows.sort(key=lambda r: r["ts"])
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$ODIR" python3 "$TP_DIR/bin/pace-json.py" || fail "古い窓回帰: pace-json.py が非ゼロ終了"
maxo7="$(jq -r '.panels[1].used | map(.[1]) | max' "$ODIR/pace.json")"
jq -e '(.panels[1].used | map(.[1]) | max) < 20' "$ODIR/pace.json" >/dev/null \
  || fail "古い窓回帰: h5r が後退した行(d7=100)が除外されずスパイク (7d系列最大=$maxo7, 期待<20)"
ok "古い窓のスナップショット除外: h5r が後退した行(d7=100)を弾き 7d はスパイクせず (系列最大=$maxo7)"

# 5p) プレイバック回帰(5h): 直近7dに重なる 5h 窓が playback.segs["5h"] として並び、窓の切替＝リセットが再現される。
#     連続する 2 つの 5h 窓（前窓 h5 が 90 まで上昇 → 現窓は 5 から再上昇）を用意し、
#     segs["5h"] が古い順に 2 セグメント／後段セグメントが低値から始まる（リセット再現）ことを検証。
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
jq -e 'has("playback") and (.playback | has("start") and has("now") and has("segs"))' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: playback(start/now/segs) が無い"
jq -e '.playback.segs["5h"] | length == 2' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: segs[\"5h\"] が 2 セグメントでない (len=$(jq -r '.playback.segs["5h"]|length' "$PDIR/pace.json"))"
jq -e '.playback.segs["5h"] | all(has("x0") and has("x1") and has("even") and has("used") and has("reset_label") and (.xmode=="time"))' \
  "$PDIR/pace.json" >/dev/null || fail "playback回帰: 5h seg に必須キー欠落 or xmode!=time"
jq -e '(.playback.segs["7d"] | length >= 1) and (.playback.segs["7d"] | all(has("x0") and has("x1") and has("even") and has("used") and (.xmode=="date")))' \
  "$PDIR/pace.json" >/dev/null || fail "playback回帰: segs[\"7d\"] が無い or 必須キー欠落 or xmode!=date"
segmax="$(jq -r '.playback.segs["5h"][0].used | map(.[1]) | max' "$PDIR/pace.json")"
segb0="$(jq -r '.playback.segs["5h"][1].used[0][1]' "$PDIR/pace.json")"
jq -e '(.playback.segs["5h"][0].used | map(.[1]) | max) >= 80' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: 前窓が高値に達していない (max=$segmax, 期待>=80)"
jq -e '.playback.segs["5h"][1].used[0][1] <= 20' "$PDIR/pace.json" >/dev/null \
  || fail "playback回帰: 現窓が低値から始まらない＝リセット未再現 (先頭=$segb0, 期待<=20)"
ok "プレイバック(5h): segs[5h]=2窓・前窓ピーク($segmax)→現窓は低値開始($segb0)でリセット再現"


# 5q) プレイバック回帰(7d): 直近7dに 7d 窓の境界をまたぐと segs["7d"] が古い順に 2 セグメントになり、
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
jq -e '.playback.segs["7d"] | length == 2' "$QDIR/pace.json" >/dev/null \
  || fail "playback7d回帰: segs[\"7d\"] が 2 窓でない (len=$(jq -r '.playback.segs["7d"]|length' "$QDIR/pace.json"))"
q7max="$(jq -r '.playback.segs["7d"][0].used | map(.[1]) | max' "$QDIR/pace.json")"
q7b0="$(jq -r '.playback.segs["7d"][1].used[0][1]' "$QDIR/pace.json")"
jq -e '(.playback.segs["7d"][0].used | map(.[1]) | max) >= 60' "$QDIR/pace.json" >/dev/null \
  || fail "playback7d回帰: 前 7d 窓が高値に達していない (max=$q7max, 期待>=60)"
jq -e '.playback.segs["7d"][1].used[0][1] <= 20' "$QDIR/pace.json" >/dev/null \
  || fail "playback7d回帰: 現 7d 窓が低値から始まらない＝リセット未再現 (先頭=$q7b0, 期待<=20)"
ok "プレイバック(7d): segs[7d]=2窓・前窓ピーク($q7max)→現窓は低値開始($q7b0)で 7d リセット再現"
# 5r) プレイバック(Codex): Codex の枠はサービス側で名目の窓長を待たずに打ち切られ、
#     名目の [リセット−窓長, リセット] が重なる（実測: 記録にある 4 回の切り替わりはすべて
#     名目の終わりまで 68〜163 時間を残して起きている）。重なりを作って、
#       ・窓ごとにセグメントが並ぶ（キーはパネル名）
#       ・使用率 0% の間に resets_at が滑っただけの 1 点の窓は落ちる
#       ・前の窓の used が次の窓の開始で切り詰められる（収集経路が 2 つあるための遅れた読み）
#     を検証する。
CPDIR="$HOME/codex-playback-test"
mkdir -p "$CPDIR"
python3 - "$CPDIR" <<'PY'
import json, os, sys, time
now = int(time.time())
d = sys.argv[1]
D = 86400
with open(os.path.join(d, "pace.jsonl"), "w") as f:      # 再生の開始位置を決めるために要る
    for k in range(7):
        f.write(json.dumps({"ts": now - 6 * D + k * D, "h5": 10, "h5r": now + 3600,
                            "d7": 20, "d7r": now + 3 * D}) + "\n")
rA, rB = now + 2 * D, now + 5 * D        # 窓A=[now-5d, now+2d] / 窓B=[now-2d, now+5d]（重なる）
rows = []
for k in range(6):                        # 窓A の観測: now-5d 〜 now-2d-2h、0→60%
    rows.append({"ts": now - 5 * D + k * (D // 2), "u": k * 12, "w": 10080, "r": rA})
for k in range(4):                        # 0% のまま resets_at が滑る＝1 点だけの見かけの窓
    ts = now - 2 * D - 3600 + k * 300
    rows.append({"ts": ts, "u": 0, "w": 10080, "r": ts + 7 * D})
for k in range(8):                        # 窓B の観測: now-2d 〜 now、0→30%
    rows.append({"ts": now - 2 * D + k * (D // 4), "u": k * 4, "w": 10080, "r": rB})
rows.append({"ts": now - 2 * D + 120, "u": 60, "w": 10080, "r": rA})   # 窓B 開始後に届いた窓A の遅れた読み
rows.sort(key=lambda r: r["ts"])
with open(os.path.join(d, "codex.jsonl"), "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$CPDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "Codex再生: pace-json.py が非ゼロ終了"
CS='.playback.segs["codex 7d"]'
jq -e "$CS | length == 2" "$CPDIR/pace.json" >/dev/null   || fail "Codex再生: セグメントが 2 窓でない (len=$(jq -r "$CS|length" "$CPDIR/pace.json")。0% で滑る窓を落とせていない可能性)"
jq -e "$CS | (.[0].x0 < .[1].x0) and (.[0].x1 > .[1].x0)" "$CPDIR/pace.json" >/dev/null   || fail "Codex再生: 名目の窓が重なる状況を作れていない（検証の前提が崩れている）"
jq -e "$CS | (.[0].used | last | .[0]) < .[1].x0" "$CPDIR/pace.json" >/dev/null   || fail "Codex再生: 前の窓の used が次の窓の開始を越えて残っている（遅れた読みの切り詰め漏れ）"
jq -e "$CS | all(has(\"x0\") and has(\"x1\") and has(\"even\") and has(\"used\") and (.xmode==\"date\") and (.key==\"codex 7d\"))" \
  "$CPDIR/pace.json" >/dev/null || fail "Codex再生: セグメントに必須キー欠落 or xmode/key が違う"
jq -e "$CS | ((.[0].used | map(.[1]) | max) >= 60) and (.[1].used[0][1] == 0)" "$CPDIR/pace.json" >/dev/null \
  || fail "Codex再生: 前窓のピーク/現窓の低値開始が再現されていない"
ok "プレイバック(Codex): 窓ごとにセグメント・0%で滑る窓を除外・次の窓の開始で切り詰め"

# 5m) 月次クレジット枠パネル: credits.jsonl があれば 3 枚目 "1mo" が出る（100% = monthly_limit）。
#     limit<=0 の行（枠が未割当のときに API が返す monthly_limit=0）は % を定義できないので除外。
#     even の分母は「窓の実就業秒」。週の総就業秒のままだと月の 1/4 あたりで 100% に張り付く
#     （＝even の点の 7 割超が 100 になる）ため、その回帰も同時に検証する。
MDIR="$HOME/month-test"
mkdir -p "$MDIR"
python3 - "$MDIR/credits.jsonl" <<'PY'
import json, sys
from datetime import datetime, timezone
now = datetime.now(timezone.utc).timestamp()
d = datetime.fromtimestamp(now, timezone.utc)
y, m = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
w1 = datetime(d.year, d.month, 1, tzinfo=timezone.utc).timestamp()   # 月境界は UTC
m1r = int(datetime(y, m, 1, tzinfo=timezone.utc).timestamp())
base = int(max(w1 + 1, now - 180))          # 必ず当月内・昇順になるように基準を取る
rows = [
    {"ts": base,      "used": 0,     "limit": 0,      "m1r": m1r},   # 枠未割当 → 除外される
    {"ts": base + 30, "used": 0,     "limit": 100000, "m1r": m1r},   # 0%
    {"ts": base + 60, "used": 1000,  "limit": 100000, "m1r": m1r},   # 1%
    {"ts": base + 90, "used": 25000, "limit": 100000, "m1r": m1r},   # 25%
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$MDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "月次回帰: pace-json.py が非ゼロ終了"
jq -e '.panels | length == 3' "$MDIR/pace.json" >/dev/null \
  || fail "月次回帰: panels が 3 でない (len=$(jq -r '.panels|length' "$MDIR/pace.json"))"
jq -e '.panels[2].key == "1mo" and .panels[2].xmode == "date"' "$MDIR/pace.json" >/dev/null \
  || fail "月次回帰: 3 枚目が 1mo(date) でない"
mnow="$(jq -r '.panels[2].used_now' "$MDIR/pace.json")"
jq -e '.panels[2].used_now == 25' "$MDIR/pace.json" >/dev/null \
  || fail "月次回帰: used_now が 25 でない (got=$mnow)"
mlen="$(jq -r '.panels[2].used | length' "$MDIR/pace.json")"
[ "$mlen" = "3" ] || fail "月次回帰: limit<=0 の行が除外されていない (used 点数=$mlen, 期待 3)"
mspan="$(jq -r '((.panels[2].x1 - .panels[2].x0) / 86400) | floor' "$MDIR/pace.json")"
{ [ "$mspan" -ge 27 ] && [ "$mspan" -le 31 ]; } || fail "月次回帰: 窓幅が 1 か月でない ($mspan 日)"
mpin="$(jq -r '((.panels[2].even | map(select(.[1] >= 99.9)) | length) * 100 / (.panels[2].even | length)) | floor' "$MDIR/pace.json")"
[ "$mpin" -lt 25 ] || fail "月次回帰: even が早期に 100% へ張り付き（分母が週のまま）: 100% の点が ${mpin}%"
# 月境界は UTC。ローカル月初だと x0 が UTC 深夜 0 時ちょうどにならない（JST なら 15:00 UTC）。
# 実測: 2026-09-01 00:00 JST を 8h40m 過ぎても used は $1000.19 のまま、00:00 UTC 直後に $0.00。
jq -e '((.panels[2].x0 | floor) % 86400 == 0) and ((.panels[2].x1 | floor) % 86400 == 0)' \
  "$MDIR/pace.json" >/dev/null \
  || fail "月次回帰: 窓境界が UTC 月初でない (x0=$(jq -r '.panels[2].x0' "$MDIR/pace.json"))"
ok "月次パネル: 3枚目=1mo・used_now=$mnow%・limit<=0 行を除外・even の飽和は ${mpin}% のみ・窓境界は UTC 月初"

# 5x) Codex パネル: rollout ログ(token_count/rate_limits)を増分収集し、primary/secondary
#     それぞれをパネル化する。実データで確認した性質を再現して検証する:
#       ・resets_at が同一窓でも数秒ゆらぐ → 許容内は同じ窓として束ねる
#       ・同一窓で used% が逆行する（並行セッションの古い観測）→ 包絡線で吸収
#       ・古い窓の観測は現在窓に混ぜない
#       ・2 回目の実行は追記分だけを読む（増分スキャン）
XDIR="$HOME/codex-test"
XHOME="$HOME/fake-codex"
mkdir -p "$XDIR" "$XHOME/sessions/2026/08/17"
ROLL="$XHOME/sessions/2026/08/17/rollout-test.jsonl"
python3 - "$ROLL" <<'PY'
import json, sys, time
now = int(time.time())
r7 = now + 3 * 86400        # 7d 窓（primary）
r5 = now + 3600             # 5h 窓（secondary）
def rec(dt, u, r, u2=None):
    p = {"type": "token_count",
         "info": {"total_token_usage": {"total_tokens": 1}},
         "rate_limits": {"limit_id": "codex", "limit_name": None,
                         "primary": {"used_percent": u, "window_minutes": 10080, "resets_at": r},
                         "secondary": None,
                         "credits": {"has_credits": True, "unlimited": False, "balance": None},
                         "plan_type": "team"}}
    if u2 is not None:
        p["rate_limits"]["secondary"] = {"used_percent": u2, "window_minutes": 300, "resets_at": r5}
    return {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now + dt)),
            "type": "event_msg", "payload": p}
rows = [
    rec(-8 * 86400, 90, r7 - 7 * 86400),   # 1 つ前の窓 → 現在窓には混ぜない
    rec(-3000, 10, r7,      20),
    rec(-2400, 20, r7 + 7),                # resets_at のゆらぎ(+7秒)
    rec(-1800, 30, r7 + 12),               # 同(+12秒)
    rec(-1200, 24, r7 + 12),               # 逆行（古い観測）→ 包絡で 30 のまま
    rec(-600,  35, r7,      60),
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
    f.write('{"type":"response_item","payload":{"type":"message","content":"SECRET-BODY"}}\n')
PY
TOKEN_PACE_DIR="$XDIR" CODEX_HOME="$XHOME" python3 "$TP_DIR/bin/codex-scan.py" \
  || fail "codex回帰: codex-scan.py が非ゼロ終了"
[ -f "$XDIR/codex.jsonl" ] || fail "codex回帰: codex.jsonl 未生成"
xrows="$(wc -l < "$XDIR/codex.jsonl" | tr -d '[:space:]')"
[ "$xrows" = "6" ] || fail "codex回帰: 収集行数が 6 でない (got=$xrows)"
if grep -q 'SECRET-BODY' "$XDIR/codex.jsonl"; then fail "codex回帰: 会話本文が codex.jsonl に混入した"; fi
tail -1 "$XDIR/codex.jsonl" | jq -e 'has("ts") and has("u") and has("w") and has("r")' >/dev/null \
  || fail "codex回帰: 収集行に必要フィールドが無い"

TOKEN_PACE_DIR="$XDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "codex回帰: pace-json.py が非ゼロ終了"
jq -e '.panels | length == 4' "$XDIR/pace.json" >/dev/null \
  || fail "codex回帰: panels が 4 でない (len=$(jq -r '.panels|length' "$XDIR/pace.json"))"
jq -e '.panels[2].key == "codex 7d" and .panels[2].xmode == "date"' "$XDIR/pace.json" >/dev/null \
  || fail "codex回帰: 3枚目が codex 7d(date) でない (got=$(jq -r '.panels[2].key' "$XDIR/pace.json"))"
jq -e '.panels[3].key == "codex 5h" and .panels[3].xmode == "time"' "$XDIR/pace.json" >/dev/null \
  || fail "codex回帰: 4枚目が codex 5h(time) でない (got=$(jq -r '.panels[3].key' "$XDIR/pace.json"))"
xn="$(jq -r '.panels[2].used_now' "$XDIR/pace.json")"
xl="$(jq -r '.panels[2].used | length' "$XDIR/pace.json")"
jq -e '.panels[2].used_now == 35 and (.panels[2].used | length) == 5' "$XDIR/pace.json" >/dev/null \
  || fail "codex回帰: 現在窓の点が想定外（used_now=$xn 点数=$xl, 期待 35 / 5＝古い窓を除外）"
jq -e '[.panels[2].used[] | select(.[1] < 30 and .[1] > 20)] | length == 0' "$XDIR/pace.json" >/dev/null \
  || fail "codex回帰: 逆行(24%)が包絡で吸収されていない"
jq -e '((.panels[2].x1 - .panels[2].x0) == 604800) and ((.panels[3].x1 - .panels[3].x0) == 18000)' \
  "$XDIR/pace.json" >/dev/null || fail "codex回帰: 窓長が window_minutes と一致しない"
jq -e '.panels[3].used_now == 60' "$XDIR/pace.json" >/dev/null \
  || fail "codex回帰: secondary(5h) の used_now が 60 でない"

# 増分スキャン: 追記した 1 行だけを読み、既読分を二重取り込みしない
python3 - "$ROLL" <<'PY'
import json, sys, time
now = int(time.time())
rec = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - 60)),
       "type": "event_msg",
       "payload": {"type": "token_count", "info": {},
                   "rate_limits": {"limit_id": "codex",
                                   "primary": {"used_percent": 40, "window_minutes": 10080,
                                               "resets_at": now + 3 * 86400},
                                   "secondary": None}}}
with open(sys.argv[1], "a") as f:
    f.write(json.dumps(rec) + "\n")
PY
TOKEN_PACE_DIR="$XDIR" CODEX_HOME="$XHOME" python3 "$TP_DIR/bin/codex-scan.py" \
  || fail "codex回帰(増分): codex-scan.py が非ゼロ終了"
xrows2="$(wc -l < "$XDIR/codex.jsonl" | tr -d '[:space:]')"
[ "$xrows2" = "7" ] || fail "codex回帰(増分): 追記分のみ取り込めていない (got=$xrows2, 期待 7)"
ok "Codex パネル: 7d/5h の 2 枚・ゆらぎ吸収・逆行を包絡・古い窓を除外・増分スキャン(${xrows}→$xrows2 行)・本文非混入"

# 5y) 終了済みの窓はパネルにしない。Codex は 5h+7d → 7d へ枠構成が変わった実績があり、
#     消えた枠の最後の観測をそのまま描くと現在の枠として誤読されるため。
YDIR="$HOME/codex-expired-test"
YHOME="$HOME/fake-codex-expired"
mkdir -p "$YDIR" "$YHOME/sessions/2026/08/17"
python3 - "$YHOME/sessions/2026/08/17/rollout-expired.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
rec = {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - 600)),
       "type": "event_msg",
       "payload": {"type": "token_count", "info": {},
                   "rate_limits": {
                       "limit_id": "codex",
                       "primary":   {"used_percent": 12, "window_minutes": 10080,
                                     "resets_at": now + 3 * 86400},      # 現在窓
                       "secondary": {"used_percent": 90, "window_minutes": 300,
                                     "resets_at": now - 30 * 86400}}}}   # 30日前に終了
with open(sys.argv[1], "w") as f:
    f.write(json.dumps(rec) + "\n")
PY
TOKEN_PACE_DIR="$YDIR" CODEX_HOME="$YHOME" python3 "$TP_DIR/bin/codex-scan.py" \
  || fail "codex期限切れ回帰: codex-scan.py が非ゼロ終了"
TOKEN_PACE_DIR="$YDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "codex期限切れ回帰: pace-json.py が非ゼロ終了"
jq -e '.panels | length == 3' "$YDIR/pace.json" >/dev/null \
  || fail "codex期限切れ回帰: 終了済み窓のパネルが出ている (len=$(jq -r '.panels|length' "$YDIR/pace.json"), 期待 3)"
jq -e '.panels[2].key == "codex 7d"' "$YDIR/pace.json" >/dev/null \
  || fail "codex期限切れ回帰: 現在窓(7d)のパネルが無い"
ok "Codex: 終了済みの窓(5h)はパネル化せず、現在窓(7d)のみ残る"

# 5w) 枠構成が戻ったとき、同じ列に残る古い枠を現在窓と取り違えない。
#     Codex は 7d の 1 枠 → 5h+7d の 2 枠へ戻した実績があり（実測 2026-08-26 08:20）、
#     このとき primary 列には 7d 時代の行が残る。その resets_at は現在の 5h 窓より
#     未来にあるため、resets_at の最大で現在窓を選ぶと古い 7d が選ばれ、
#     「codex 7d」が 2 枚出て現在の 5h が消える。最新の観測が属する窓を選ぶ。
WDIR="$HOME/codex-refill-test"
WHOME="$HOME/fake-codex-refill"
mkdir -p "$WDIR" "$WHOME/sessions/2026/08/26"
python3 - "$WHOME/sessions/2026/08/26/rollout-refill.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
old_r = now + 5 * 86400      # 7d 時代の残骸（まだ未来）
cur_r = now + 3600           # 現在の 5h 窓
sec_r = now + 6 * 86400      # 現在の 7d 窓
def rec(dt, u, w, r, sec=None):
    rl = {"limit_id": "codex",
          "primary": {"used_percent": u, "window_minutes": w, "resets_at": r},
          "secondary": None}
    if sec:
        rl["secondary"] = {"used_percent": sec[0], "window_minutes": sec[1], "resets_at": sec[2]}
    return {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now + dt)),
            "type": "event_msg",
            "payload": {"type": "token_count", "info": {}, "rate_limits": rl}}
rows = [
    rec(-30 * 3600, 50, 10080, old_r),                          # 30 時間前＝7d 時代の最後の観測
    rec(-1200, 10, 300, cur_r, (28, 10080, sec_r)),             # 現在の 5h + 7d
    rec(-600,  20, 300, cur_r, (30, 10080, sec_r)),
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$WDIR" CODEX_HOME="$WHOME" python3 "$TP_DIR/bin/codex-scan.py" \
  || fail "codex枠復活回帰: codex-scan.py が非ゼロ終了"
TOKEN_PACE_DIR="$WDIR" python3 "$TP_DIR/bin/pace-json.py" \
  || fail "codex枠復活回帰: pace-json.py が非ゼロ終了"
jq -e '.panels | length == 4' "$WDIR/pace.json" >/dev/null \
  || fail "codex枠復活回帰: panels が 4 でない (len=$(jq -r '.panels|length' "$WDIR/pace.json"))"
jq -e '[.panels[2].key, .panels[3].key] | unique | length == 2' "$WDIR/pace.json" >/dev/null \
  || fail "codex枠復活回帰: 同じ key のパネルが 2 枚出ている ($(jq -r '[.panels[2].key,.panels[3].key]|join(" / ")' "$WDIR/pace.json"))"
jq -e '.panels[2].key == "codex 5h" and .panels[2].used_now == 20' "$WDIR/pace.json" >/dev/null \
  || fail "codex枠復活回帰: 現在の 5h 枠が出ていない (got=$(jq -r '.panels[2].key' "$WDIR/pace.json") used=$(jq -r '.panels[2].used_now' "$WDIR/pace.json"))"
jq -e '.panels[3].key == "codex 7d" and .panels[3].used_now == 30' "$WDIR/pace.json" >/dev/null \
  || fail "codex枠復活回帰: 現在の 7d 枠が出ていない (got=$(jq -r '.panels[3].key' "$WDIR/pace.json"))"
jq -e '[.panels[] | select(.used_now == 50)] | length == 0' "$WDIR/pace.json" >/dev/null \
  || fail "codex枠復活回帰: 30 時間前の古い 7d 枠が現在窓として描かれている"
ok "Codex: 5h 枠の復活時、同列に残る古い 7d を現在窓と取り違えない（codex 5h + codex 7d）"

# 5z) Codex の app-server 経路(codex-fetch.py): 会話が無くても現在の枠が取れる。
#     rollout に rate_limits が載るのは会話したときだけで、TUI の /status は
#     app-server の account/rateLimits/read を叩いて結果をディスクに残さない。
#     そのため会話しない期間は codex-scan.py では現在値が取れない。ここは同じ
#     JSON-RPC を話す fake に CODEX_BIN を差し替えて検証する。
ZDIR="$HOME/codex-fetch-test"
FAKE_CODEX="$HOME/fake-codex-bin"
mkdir -p "$ZDIR"
cat > "$FAKE_CODEX" <<'PY'
#!/usr/bin/env python3
# `codex app-server` の代替。stdin の JSON-RPC に答えるだけ。
import json, os, sys
mode = os.environ.get("FAKE_MODE", "ok")
WIN = {"usedPercent": 37, "windowDurationMins": 10080, "resetsAt": int(os.environ["FAKE_R"])}
SEC = {"usedPercent": 12, "windowDurationMins": 300,   "resetsAt": int(os.environ["FAKE_R5"])}
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("id") == 1:
        print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"userAgent": "fake"}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "method": "configWarning",
                          "params": {}}), flush=True)      # 通知が混ざっても読み飛ばせるか
    elif m.get("id") == 2:
        snap = {"limitId": "codex",
                "primary":   None if mode == "null" else WIN,
                "secondary": SEC if mode == "both" else None,
                "planType": "team",
                "rateLimitReachedType":
                    "workspace_member_usage_limit_reached" if mode == "null" else None}
        print(json.dumps({"jsonrpc": "2.0", "id": 2,
                          "result": {"rateLimits": snap}}), flush=True)
PY
chmod +x "$FAKE_CODEX"
_now="$(date +%s)"
export FAKE_R=$(( _now + 3 * 86400 )) FAKE_R5=$(( _now + 3600 ))

FAKE_MODE=both CODEX_BIN="$FAKE_CODEX" TOKEN_PACE_DIR="$ZDIR" \
  python3 "$TP_DIR/bin/codex-fetch.py" || fail "codex-fetch: 非ゼロ終了"
[ -f "$ZDIR/codex.jsonl" ] || fail "codex-fetch: codex.jsonl 未生成"
zrows="$(wc -l < "$ZDIR/codex.jsonl" | tr -d '[:space:]')"
[ "$zrows" = "1" ] || fail "codex-fetch: 1 行追記されていない (got=$zrows)"
tail -1 "$ZDIR/codex.jsonl" | jq -e --argjson r "$FAKE_R" --argjson r5 "$FAKE_R5" \
  '.u == 37 and .w == 10080 and .r == $r and .u2 == 12 and .w2 == 300 and .r2 == $r5 and (.ts | type) == "number"' \
  >/dev/null || fail "codex-fetch: 追記内容が想定と違う ($(tail -1 "$ZDIR/codex.jsonl"))"

# 枠到達で primary が null の期間は記録しない（codex-scan.py と同じ規律）
FAKE_MODE=null CODEX_BIN="$FAKE_CODEX" TOKEN_PACE_DIR="$ZDIR" \
  python3 "$TP_DIR/bin/codex-fetch.py" || fail "codex-fetch(primary=null): 非ゼロ終了"
znull="$(wc -l < "$ZDIR/codex.jsonl" | tr -d '[:space:]')"
[ "$znull" = "1" ] || fail "codex-fetch(primary=null): 行が増えた (got=$znull)"

# codex が入っていない環境でも黙って何もしない
CODEX_BIN="$HOME/no-such-codex" TOKEN_PACE_DIR="$ZDIR" \
  python3 "$TP_DIR/bin/codex-fetch.py" || fail "codex-fetch(codex 不在): 非ゼロ終了"
zmiss="$(wc -l < "$ZDIR/codex.jsonl" | tr -d '[:space:]')"
[ "$zmiss" = "1" ] || fail "codex-fetch(codex 不在): 行が増えた (got=$zmiss)"

# 同じ codex.jsonl を 2 つのプロセスが書くので、ロックは共有していなければならない
# （別ロックだと _prune の read-all→replace 中の append で行が消える）
grep -q '"\.codex\.lock"' "$TP_DIR/bin/codex-fetch.py" \
  || fail "codex-fetch: ロックが .codex.lock でない"
grep -q '"\.codex\.lock"' "$TP_DIR/bin/codex-scan.py" \
  || fail "codex-scan: ロックが .codex.lock でない"

TOKEN_PACE_DIR="$ZDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "codex-fetch: pace-json.py が非ゼロ終了"
jq -e '.panels | length == 4' "$ZDIR/pace.json" >/dev/null \
  || fail "codex-fetch: panels が 4 でない (len=$(jq -r '.panels|length' "$ZDIR/pace.json"))"
jq -e '.panels[2].key == "codex 7d" and .panels[2].used_now == 37 and (.panels[2].used | length) == 1' \
  "$ZDIR/pace.json" >/dev/null || fail "codex-fetch: 1 点だけの codex 7d パネルにならない"
jq -e '.panels[3].key == "codex 5h" and .panels[3].used_now == 12' "$ZDIR/pace.json" >/dev/null \
  || fail "codex-fetch: secondary(5h) のパネルが出ていない"
unset FAKE_R FAKE_R5
ok "Codex(app-server): 会話なしで現在値を取得・通知を読み飛ばす・primary=null と codex 不在は無記録・ロック共有"

# 5h2) 履歴モードの系列: 全パネル共通の時間軸（既定は直近 1 か月。データがそれより
#      短ければ最古の記録まで）に、過去の窓も含めた used% を並べる。窓ごとに
#      envelope するので窓の境界で値が戻る鋸歯になる（通しで running-max すると
#      どの窓のピークも引きずって 100% の平線になってしまう）。stale 行は現在窓と
#      同じく除外する。
HDIR="$HOME/hist-test"
mkdir -p "$HDIR"
python3 - "$HDIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
rows = []
# 3 つの 5h 窓。各窓で値が上がり、次の窓は低値から再開する（＝境界で戻る）
# ts は必ず now 以前かつ h5r より前（h5r <= ts の行は stale として捨てられるため）
for k, (reset, pts) in enumerate([
        (now - 6 * 3600, [(-9 * 3600, 10), (-8 * 3600, 50), (-7 * 3600, 90)]),   # 2 つ前の窓
        (now - 1 * 3600, [(-4 * 3600, 5), (-3 * 3600, 40), (-2 * 3600, 70)]),    # 1 つ前の窓
        (now + 4 * 3600, [(-2400, 3), (-1200, 20)])]):                           # 現在の窓
    for dt, v in pts:
        rows.append({"ts": now + dt, "h5": v, "h5r": reset,
                     "d7": v, "d7r": now + 3 * 86400, "cost": 1.0, "sid": f"w{k}"})
# stale: 観測時点で既に過ぎた 5h リセットを持つ行（履歴でも捨てられること）
rows.append({"ts": now - 1800, "h5": 99, "h5r": now - 2 * 3600,
             "d7": 99, "d7r": now + 3 * 86400, "cost": 1.0, "sid": "stale"})
rows.sort(key=lambda r: r["ts"])
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$HDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "履歴回帰: pace-json.py が非ゼロ終了"
jq -e 'has("hist_x0") and has("hist_x1")' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: hist_x0 / hist_x1 が出ていない"
# 1 か月に満たないので左端は最古の記録
hx0="$(jq -r '.panels[0].hist[0][0]' "$HDIR/pace.json")"
jq -e --argjson t "$hx0" '.hist_x0 <= $t' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: hist_x0 が最古の記録より後ろ"
jq -e '.hist_x1 - .hist_x0 < 2*86400' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: データが 1 日ぶんしか無いのに軸が 2 日以上ある（最古へ寄せていない）"
jq -e '(.panels[0].hist | length) >= 6' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: 5h の履歴が短すぎる (len=$(jq -r '.panels[0].hist|length' "$HDIR/pace.json"))"
# 窓の境界で値が戻る＝下降が 2 回以上ある（通しで包絡すると 0 回になる）
drops="$(python3 - "$HDIR/pace.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["panels"][0]["hist"]
print(sum(1 for i in range(1, len(h)) if h[i][1] < h[i-1][1]))
PY
)"
[ "$drops" -ge 2 ] || fail "履歴回帰: 窓の境界で値が戻っていない（下降 $drops 回、期待 2 回以上）"
jq -e '[.panels[0].hist[] | select(.[1] == 99)] | length == 0' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: stale 行(99%)が履歴に混入した"
jq -e '(.panels[0].hist | map(.[1]) | max) == 90' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: 5h 履歴の最大が 90 でない (got=$(jq -r '.panels[0].hist|map(.[1])|max' "$HDIR/pace.json"))"
jq -e '(.panels[1].hist | length) > 0' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: 7d の履歴が空"
# 現在窓の系列（used）は履歴を入れても変わらない
jq -e '.panels[0].used_now == 20 and (.panels[0].used | length) == 2' "$HDIR/pace.json" >/dev/null \
  || fail "履歴回帰: 現在窓の系列が壊れた (used_now=$(jq -r '.panels[0].used_now' "$HDIR/pace.json"))"
ok "履歴モード: 共通軸(最古まで)・窓ごとに包絡し境界で戻る(下降 $drops 回)・stale 除外・現在窓は不変"

# 5v) 履歴の異常パターン除去: 「窓が後戻りする行」と「h5r を持たない行」を弾く。
#     どちらも別セッションが持っていた古いスナップショットで、包絡の running-max が
#     跳ね返って 100→0→100 のような形になる。実測で両方とも発生している
#     （08/19 15:00 の 7d リセット直後に前の窓の 98% / 09/02 08:51 に h5r 欠落の 100%）。
VDIR="$HOME/hist-anomaly-test"
mkdir -p "$VDIR"
python3 - "$VDIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
old_r, new_r = now - 3600, now + 6 * 86400      # 前の 7d 窓 / 現在の 7d 窓
h5r = now + 3600                                # 5h リセットは常に未来（stale 判定を通す）
rows = [
    {"ts": now - 5 * 3600, "h5": 10, "h5r": h5r, "d7": 90, "d7r": old_r},
    {"ts": now - 4 * 3600, "h5": 11, "h5r": h5r, "d7": 90, "d7r": old_r},
    {"ts": now - 1800,     "h5": 12, "h5r": h5r, "d7":  5, "d7r": new_r},
    {"ts": now - 1200,     "h5": 13, "h5r": h5r, "d7":  6, "d7r": new_r},
    # 新しい窓を見たあとで前の窓を報告する行（別セッションの古いスナップショット）
    {"ts": now - 900,      "h5": 14, "h5r": h5r, "d7": 90, "d7r": old_r},
    {"ts": now - 600,      "h5": 15, "h5r": h5r, "d7":  7, "d7r": new_r},
    # h5r を持たない行（statusLine に five_hour ブロックが無い応答）
    {"ts": now - 300,      "h5": None, "h5r": None, "d7": 99, "d7r": new_r},
    {"ts": now - 60,       "h5": 16, "h5r": h5r, "d7":  8, "d7r": new_r},
]
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
TOKEN_PACE_DIR="$VDIR" python3 "$TP_DIR/bin/pace-json.py" || fail "履歴異常回帰: pace-json.py が非ゼロ終了"
jq -e '[.panels[1].hist[] | select(.[1] == 99)] | length == 0' "$VDIR/pace.json" >/dev/null \
  || fail "履歴異常回帰: h5r を持たない行(99%)が履歴に混入した"
jq -e '[.panels[1].used[] | select(.[1] == 99)] | length == 0' "$VDIR/pace.json" >/dev/null \
  || fail "履歴異常回帰: h5r を持たない行(99%)が現在窓に混入した"
vdec="$(python3 - "$VDIR/pace.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["panels"][1]["hist"]
print(sum(1 for i in range(1, len(h)) if h[i][1] < h[i-1][1]))
PY
)"
[ "$vdec" = "1" ] || fail "履歴異常回帰: 窓の切替は 1 回のはずが $vdec 回（後戻りした窓が混ざっている）"
vrise="$(python3 - "$VDIR/pace.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["panels"][1]["hist"]
print(sum(1 for i in range(1, len(h)) if h[i][1] - h[i-1][1] >= 20))
PY
)"
[ "$vrise" = "0" ] || fail "履歴異常回帰: 20pt 以上の急上昇が $vrise 回（100→0→100 の形）"
jq -e '(.panels[1].hist | map(.[1]) | max) == 90' "$VDIR/pace.json" >/dev/null \
  || fail "履歴異常回帰: 前の窓のピーク 90 が失われた"
ok "履歴の異常除去: 後戻りする窓と h5r 欠落行を弾き、急上昇 0・窓の切替 1 回"

# 5f) 予測の帯: 別ツール(claude-codex-router)が定期的に書く forecast.json を、側とリセット時刻で
#     パネルに突き合わせる。届くのは標本そのもの（窓ごとに ts[] と paths[][]）で、分位の切り出しは
#     こちら持ち。窓の名前は相手の都合で変わり得るが、同じ窓ならリセット時刻は一致する。
#     予測が今に合っているかは「起点 u と今の used% の差」1 本で見る。外れても捨てず、
#     fc.stale を立てて描き方（黄・薄く）で示す。消すと理由が伝わらないため。
#     相手の出力仕様は変わり得るので、形が違う・ファイルが無いときに他の表示が変わらないことまで見る。
FDIR="$HOME/forecast-test"
mkdir -p "$FDIR"
python3 - "$FDIR/pace.jsonl" <<'PY'
import json, sys, time
now = int(time.time())
h5r, d7r = now + 3600, now + 6 * 86400
with open(sys.argv[1], "w") as f:
    for i in range(5):
        f.write(json.dumps({"ts": now - 600 + i * 120, "h5": 10 + i, "h5r": h5r,
                            "d7": 5 + i, "d7r": d7r}) + "\n")
PY
# $1=出力先 $2=予測を何秒前に出したことにするか $3=リセットのずれ秒 $4=起点 u のずれ(pt)
gen_fc() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys, time
now = int(time.time())
age, drift, udrift = int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
NS, NP = 8, 20                                   # ステップ数 / 標本数
def win(side, r, u):                             # u は pace.jsonl の末尾の used% に合わせる
    ts = [now + (r - now) * (k + 1) / NS for k in range(NS)]
    paths = [[u + udrift + i * 0.5 * (k + 1) for k in range(NS)] for i in range(NP)]
    return {"side": side, "u": u + udrift, "r": r, "win": (r - now) / 60,
            "step_s": (r - now) / NS, "ts": ts, "paths": paths}
json.dump({"t": now - age, "n": NP, "windows": {
    "claude-session":    win("claude", now + 3600 + drift, 14),
    "claude-weekly_all": win("claude", now + 6 * 86400 + drift, 9)}}, open(sys.argv[1], "w"))
PY
}
fc_run() {   # $1=FORECAST_JSON に渡す値 → pace.json を作り直す
  FORECAST_JSON="$1" TOKEN_PACE_DIR="$FDIR" python3 "$TP_DIR/bin/pace-json.py" \
    || fail "予測回帰: pace-json.py が非ゼロ終了 (FORECAST_JSON=$1)"
}
fc_has()   { jq -r '[.panels[] | has("fc")] | map(select(.)) | length' "$FDIR/pace.json"; }
fc_stale() { jq -r "[.panels[] | select(has(\"fc\")) | .fc.stale] | map(select(.)) | length" "$FDIR/pace.json"; }

gen_fc "$FDIR/forecast.json" 0 0 0
fc_run "$FDIR/forecast.json"
[ "$(fc_has)" = "2" ] || fail "予測回帰: 5h/7d の両方に fc が載っていない (載った枚数=$(fc_has))"
[ "$(fc_stale)" = "0" ] || fail "予測回帰: 起点が合っているのに stale が立った"
jq -e '.panels[0].fc.levels | length == 19' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: 分位の段階数がこちらの設定（19）になっていない"
jq -e '.panels[0].fc.pts | length == 8 and all(.[]; length == 20)' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: pts が [ts, 分位 19 個] の形でない"
jq -e '.panels[0].fc.pts | map(.[0]) | (. == (. | sort))' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: pts の時刻が昇順でない"
jq -e '.panels[0].fc.pts[0] | .[1] <= .[10] and .[10] <= .[19]' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: 分位が昇順に並んでいない（切り出しの誤り）"
jq -e '.panels[0].fc.p_full != null' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: p_full を標本から出せていない"
u5base="$(jq -r '.panels[0].used_now' "$FDIR/pace.json")"

# 規則は起点のずれ 1 本。経過時間では判定しない（以前は窓の長さの 5% で別に落としていた）。
gen_fc "$FDIR/old.json" 86400 0 0
fc_run "$FDIR/old.json"
[ "$(fc_has)" = "2" ]   || fail "予測回帰: 1 日前でも起点が合っていれば使うはずが落ちた"
[ "$(fc_stale)" = "0" ] || fail "予測回帰: 経過時間だけで stale を立てている"

# 起点が離れたら捨てずに stale を立てる（描画側が黄・薄くする）
gen_fc "$FDIR/udrift.json" 0 0 6
fc_run "$FDIR/udrift.json"
[ "$(fc_has)" = "2" ]   || fail "予測回帰: 起点がずれた予測を捨ててしまった（消すと理由が伝わらない）"
[ "$(fc_stale)" = "2" ] || fail "予測回帰: 起点が 6pt ずれたのに stale が立たない"
gen_fc "$FDIR/uok.json" 0 0 4
fc_run "$FDIR/uok.json"
[ "$(fc_stale)" = "0" ] || fail "予測回帰: 起点のずれ 4pt（許容内）で stale が立った"

gen_fc "$FDIR/drift.json" 0 200 0      # リセットが許容 120 秒を超えてずれる＝別の窓
fc_run "$FDIR/drift.json"
[ "$(fc_has)" = "0" ] || fail "予測回帰: リセットが 200 秒ずれた窓を取り違えた"

python3 - "$FDIR/ragged.json" <<'PY'
import json, sys, time
now = int(time.time())                     # 標本の長さが ts と合わない行は捨てる
ts = [now + 3600 * (k + 1) / 8 for k in range(8)]
paths = [[14.0] * 8, [14.0] * 5, [14.0] * 8]
json.dump({"t": now, "n": 3, "windows": {"w": {
    "side": "claude", "u": 14, "r": now + 3600, "ts": ts, "paths": paths}}}, open(sys.argv[1], "w"))
PY
fc_run "$FDIR/ragged.json"
jq -e '.panels[0].fc.pts | length == 8' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: 長さの合わない標本で帯が壊れた"

printf '{"windows": {' > "$FDIR/broken.json"   # 追記途中で切れたファイル
fc_run "$FDIR/broken.json"
[ "$(fc_has)" = "0" ] || fail "予測回帰: 壊れた JSON から fc を作ってしまった"

printf '[1,2,3]' > "$FDIR/noobj.json"          # 形が違う（辞書でない）
fc_run "$FDIR/noobj.json"
[ "$(fc_has)" = "0" ] || fail "予測回帰: 辞書でない JSON から fc を作ってしまった"

fc_run "$FDIR/does-not-exist.json"             # ファイルが無い＝相手が未導入
[ "$(fc_has)" = "0" ] || fail "予測回帰: 存在しないファイルで fc が載った"
jq -e '.panels | length == 2 and all(has("used"))' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: 予測が無いときに他のパネルが壊れた"
jq -e --argjson u "$u5base" '.panels[0].used_now == $u' "$FDIR/pace.json" >/dev/null \
  || fail "予測回帰: 予測の有無で used_now が変わった"
ok "予測の帯: 標本から分位を切り出し・判定は起点のずれ 1 本・外れても捨てず stale・窓違い/壊れた形/無しは捨て、他は不変"

# 5g) 予測の履歴(forecast-hist.bin): 再生中にも帯を出すため、15 分格子で追記して
#     7 日ぶん持つ。形式は uint16 の時間方向差分。同じ格子では増えないこと、
#     復元した値が pace.json の fc と一致すること、古いものが落ちることを見る。
rm -f "$FDIR/forecast-hist.bin"
gen_fc "$FDIR/forecast.json" 0 0 0
fc_run "$FDIR/forecast.json"
[ -f "$FDIR/forecast-hist.bin" ] || fail "予測の履歴: forecast-hist.bin が作られない"
hsz1="$(wc -c < "$FDIR/forecast-hist.bin" | tr -d '[:space:]')"
fc_run "$FDIR/forecast.json"
hsz2="$(wc -c < "$FDIR/forecast-hist.bin" | tr -d '[:space:]')"
[ "$hsz1" = "$hsz2" ] || fail "予測の履歴: 同じ 15 分格子で二重に追記された ($hsz1 -> $hsz2)"
TP_BIN="$TP_DIR/bin/pace-json.py" python3 - "$FDIR" <<'PY' || fail "予測の履歴: 復元や切り詰めが不正"
import importlib.util, json, os, struct, sys
spec = importlib.util.spec_from_file_location("pacejson", os.environ["TP_BIN"])
pj = importlib.util.module_from_spec(spec); spec.loader.exec_module(pj)
fdir = sys.argv[1]
pj.TP_DIR = fdir
pj.FC_HIST_OUT = os.path.join(fdir, "forecast-hist.bin")
d = json.load(open(os.path.join(fdir, "pace.json")))
by_key = {p["key"]: p for p in d["panels"]}
want = {p["key"] for p in d["panels"] if p.get("fc")}   # 予測が付いている枠はすべて書く
panels = d["panels"]
ok, recs = pj._fch_read(pj.FC_HIST_OUT)
if not ok or len(recs) != len(want):
    sys.exit("履歴を読み戻せない (ok=%s n=%d 期待=%d)" % (ok, len(recs), len(want)))
head, buf = pj._fch_header(), open(pj.FC_HIST_OUT, "rb").read()
L, i, seen = len(pj.FORECAST_LEVELS), len(head), set()
while i < len(buf):
    _slot, klen, tend, step, n, u = struct.unpack_from(pj.FC_HIST_HEAD, buf, i)
    i += pj.FC_HIST_HEAD_SZ
    key = buf[i:i + klen].decode("utf-8"); i += klen
    seen.add(key)
    if key not in by_key:
        sys.exit("知らない枠のキー %r" % key)
    vals = struct.unpack_from("<%dH" % (n * L), buf, i); i += 2 * n * L
    src = by_key[key]["fc"]["pts"]
    if n != len(src):
        sys.exit("ステップ数が違う (%d != %d)" % (n, len(src)))
    acc = [0] * L
    for j in range(n):
        tj = tend - (n - 1 - j) * step / 100.0
        if abs(tj - src[j][0]) > 1.0:
            sys.exit("時刻が復元できない (%.2f != %.2f)" % (tj, src[j][0]))
        for k in range(L):
            acc[k] += vals[j * L + k]
            if abs(acc[k] / 10.0 - src[j][1 + k]) > 0.05:
                sys.exit("値が復元できない (%.3f != %.3f)" % (acc[k] / 10.0, src[j][1 + k]))
    if abs(u / 10.0 - (by_key[key]["used_now"] or 0)) > 0.05:
        sys.exit("起点 u が違う")
if seen != want:
    sys.exit("予測が付いている枠が全部書かれていない (%s != %s)" % (sorted(seen), sorted(want)))
# 7 日を越えた追記で古いレコードが落ちる
pj.append_forecast_hist(panels, d["generated_at"] + pj.PLAYBACK_SPAN + pj.FC_HIST_SLOT)
ok2, recs2 = pj._fch_read(pj.FC_HIST_OUT)
if not ok2 or len(recs2) != len(want):
    sys.exit("7 日より古いレコードが落ちていない (n=%d)" % len(recs2))
# 分位の並びが変わったら読まずに作り直す
pj.FORECAST_LEVELS = tuple(round(0.1 * k, 2) for k in range(1, 10))
if pj._fch_read(pj.FC_HIST_OUT)[0]:
    sys.exit("分位の並びが変わったファイルをそのまま読んだ")
PY
ok "予測の履歴: 予測が付いた枠をすべて 15 分格子で追記・二重なし・値と時刻が復元できる・7 日で切り詰め・分位変更で作り直し"

# 5u) 使用量の取得: epoch のリセット時刻で書き、間引き中は何もしない(rc=2)
UDIR="$HOME/udir"; mkdir -p "$UDIR"
cat > "$UDIR/usage.json" <<'JSON'
{"five_hour":{"utilization":18,"resets_at":"2030-01-01T00:00:00Z"},
 "seven_day":{"utilization":7.5,"resets_at":"2030-01-02T00:00:00Z"}}
JSON
TOKEN_PACE_DIR="$UDIR" TOKEN_PACE_USAGE_URL="file://$UDIR/usage.json" \
  python3 "$TP_DIR/bin/usage-fetch.py" || fail "usage-fetch.py が行を書かない"
urow="$(tail -1 "$UDIR/pace.jsonl")"
echo "$urow" | jq -e '.src=="api" and .h5==18 and .d7==7.5
  and (.h5r|type)=="number" and .h5r==1893456000 and (.d7r|type)=="number"' >/dev/null \
  || fail "usage-fetch.py の行が不正: $urow"
set +e
TOKEN_PACE_DIR="$UDIR" TOKEN_PACE_USAGE_URL="file://$UDIR/usage.json" \
  python3 "$TP_DIR/bin/usage-fetch.py"; urc=$?
set -e
[ "$urc" = "2" ] || fail "間引き中の usage-fetch.py が rc=${urc}（2 を期待）"
# 取得できない場合は記録しない（代替手段は持たない）
rm -f "$UDIR/.last_usage"            # 間引きを解いて取得そのものを試させる
set +e
TOKEN_PACE_DIR="$UDIR" TOKEN_PACE_USAGE_URL="file://$UDIR/no-such.json" \
  python3 "$TP_DIR/bin/usage-fetch.py"; urc2=$?
set -e
if [ "$urc2" != "1" ] || [ "$(tail -1 "$UDIR/pace.jsonl")" != "$urow" ]; then
  fail "取得失敗時に rc=1 で何も書かないこと (rc=$urc2)"
fi
ok "使用量の取得: epoch のリセット時刻で記録・間引きで rc=2・取得失敗で rc=1（何も書かない）"

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
# 再生用の予測の履歴も配信する（gzip を求められたら gzip で返す）
cp "$FDIR/forecast-hist.bin" "$TP_DIR/forecast-hist.bin"
fcode="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/forecast-hist.bin")"
[ "$fcode" = "200" ] || fail "GET /forecast-hist.bin が $fcode"
fenc="$(curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip' "http://127.0.0.1:$PORT/forecast-hist.bin" \
         | tr -d '\r' | awk -F': ' 'tolower($1)=="content-encoding"{print $2}')"
[ "$fenc" = "gzip" ] || fail "forecast-hist.bin が gzip で返らない (Content-Encoding=$fenc)"
fmagic="$(curl -s --compressed "http://127.0.0.1:$PORT/forecast-hist.bin" | head -c 4)"
[ "$fmagic" = "TPFC" ] || fail "配信された forecast-hist.bin の中身が違う ($fmagic)"
ok "serve.sh が / と /pace.json と /forecast-hist.bin（gzip）を配信 (port=$PORT pid=$SRV_PID)"

# 6b) ハードニング: 記録ファイル/元 statusLine は配信しない（ホワイトリスト外は 404）
for badpath in /pace.jsonl /.orig_statusline /config.json; do
  bc="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$badpath")"
  [ "$bc" = "404" ] || fail "非公開パス $badpath が配信された (HTTP $bc)"
done
# 6c) ハードニング: 別 Host（DNS リバインド）は 403 で拒否
hc="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "http://127.0.0.1:$PORT/pace.json")"
[ "$hc" = "403" ] || fail "異なる Host を拒否しない (HTTP $hc)"
ok "配信はホワイトリストの 3 パスに限定・別 Host を拒否（DNS リバインド対策）"

# 7) 冪等性: 2 回目の install はラッパーを二重化せず、元コマンドも上書きしない
do_install || fail "2 回目のインストール($MODE) が失敗"
[ "$(jq -r '.statusLine.command' "$SETTINGS")" = "$WRAPPER" ] \
  || fail "冪等性: statusLine がラッパーを指していない"
[ "$(cat "$TP_DIR/.orig_statusline")" = "echo ORIG-STATUSLINE-OK" ] \
  || fail "冪等性: 元の statusLine がラッパー自身で上書きされた（ラッパーが自分を呼び続ける）"
[ -x "$TP_DIR/bin/tick.sh" ] || fail "冪等性: tick.sh が消えた"
ok "install は冪等（ラッパーを二重化せず・元の statusLine を保持）"

# 8) uninstall が statusLine を復元しコマンド/サーバを片付ける
bash "$TP_DIR/uninstall.sh" >/dev/null || fail "uninstall.sh が失敗"
restored="$(jq -r '.statusLine.command' "$SETTINGS")"
[ "$restored" = "echo ORIG-STATUSLINE-OK" ] || fail "uninstall が statusLine を壊した (got: $restored)"
[ ! -f "$HOME/.claude/commands/tpw.md" ] || fail "uninstall が /tpw を削除しない"
if kill -0 "$SRV_PID" 2>/dev/null; then fail "uninstall がサーバを停止しない (pid $SRV_PID 生存)"; fi
SRV_PID=""
ok "uninstall: /tpw 削除・サーバ停止・statusLine を元に戻す"

verify_uid_resources || exit 1
ok "実ユーザーの systemd timer・ユニットファイル・crontab は試験の前後で不変"

echo "🎉 smoke test PASSED"
