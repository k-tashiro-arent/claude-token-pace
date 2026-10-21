#!/usr/bin/env python3
"""月次クレジット枠(extra usage)を取得して credits.jsonl に追記する。

statusLine の JSON に載るレート枠は 5h/7d の used%/resets_at だけで、月次のクレジット
消費（プラン枠を超えた分の支出）は含まれない。そのため Claude Code 自身が使うのと同じ
エンドポイント GET /api/oauth/usage から取得する。

- 認証 : $CLAUDE_CONFIG_DIR(既定 ~/.claude)/.credentials.json の claudeAiOauth.accessToken
         （macOS はこのファイルが無く Keychain に入るので、security コマンドで読む）
         を読むだけ。期限切れ・不在なら何もしない（refresh は Claude Code 本体に任せる。
         ここで refresh すると refreshToken のローテーションで本体の認証を壊しうる）。
- 出力 : $TOKEN_PACE_DIR/credits.jsonl  {ts, used, limit, m1r, en}
         used/limit は API の minor 単位そのまま（USD なら cent）。
         m1r = 翌月1日 00:00(ローカル) の epoch＝この枠のリセット時刻。
         en  = extra_usage.is_enabled＝枠そのものの有無。枠が無効でも monthly_limit に
               前の値が残ることがあるため、金額とは別にこのフラグを残す。
- 失敗 : 何が起きても exit 0（statusLine / サンプリングに波及させない）。
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

TP_DIR = os.path.expanduser(os.environ.get("TOKEN_PACE_DIR") or "~/.claude/token-pace")
CFG_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
CRED = os.path.join(CFG_DIR, ".credentials.json")
OUT = os.path.join(TP_DIR, "credits.jsonl")
LOCK = os.path.join(TP_DIR, ".credits.lock")

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA = "oauth-2025-04-20"
TIMEOUT = 5

MAX_LINES = 20000      # 肥大時はこの行数までに prune
KEEP_LINES = 12000     # prune 後に残す行数（月次窓に必要な 1 か月分を割らない量）


# macOS では Claude Code が認証情報をファイルではなく Keychain に入れる（ファイルに出す
# 公式の方法は無く、要望 issue も not planned で閉じている）。中身は同じ JSON なので、
# ファイルが無いときだけ security コマンドで読む。別プロセスからの読み出しは Keychain の
# 許可を求められることがあるため、短いタイムアウトで諦める（定期実行は画面の無い文脈で
# 走ることがある）。サービス名は版によって違う例が報告されているので順に試す。
KEYCHAIN_SERVICES = ("Claude Code-credentials", "Claude Code")
SECURITY_BIN = os.environ.get("TOKEN_PACE_SECURITY_BIN") or "security"


def keychain_credentials():
    """Keychain に入っている認証情報の JSON。読めなければ None。"""
    if sys.platform != "darwin" and not os.environ.get("TOKEN_PACE_SECURITY_BIN"):
        return None
    for service in KEYCHAIN_SERVICES:
        try:
            p = subprocess.run([SECURITY_BIN, "find-generic-password", "-s", service, "-w"],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.SubprocessError):
            return None
        if p.returncode == 0 and p.stdout.strip():
            try:
                return json.loads(p.stdout.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return None
    return None



def access_token(now_epoch):
    """有効な OAuth アクセストークンを返す。無い/期限切れなら None。"""
    try:
        with open(CRED, "r", encoding="utf-8") as f:
            cred = json.load(f)
    except (OSError, ValueError):
        cred = keychain_credentials()      # macOS はファイルが無く Keychain に入る
        if not isinstance(cred, dict):
            return None
    oauth = cred.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return None
    token = oauth.get("accessToken")
    if not isinstance(token, str) or not token:
        return None
    exp = oauth.get("expiresAt")     # ミリ秒
    try:
        if exp is not None and float(exp) / 1000.0 <= now_epoch:
            return None              # 期限切れ。本体がリフレッシュするまで待つ
    except (ValueError, TypeError):
        pass
    return token


def fetch_usage(token):
    """GET /api/oauth/usage。失敗したら None。"""
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "anthropic-beta": OAUTH_BETA,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
            return json.loads(res.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError):
        return None


def next_month_start(epoch):
    """epoch を含む月の翌月 1 日 00:00(UTC) の epoch。

    月次クレジット枠のリセットは UTC の月初。ローカル月初ではない（実測:
    2026-08-31 23:40:08 UTC に used=$1000.19 → 2026-09-01 00:05:16 UTC に $0.00。
    ローカル月初の 2026-09-01 00:00 JST を 8 時間 40 分過ぎた時点では未リセットだった）。
    API に月次枠の resets_at は無いため、境界はこの実測に基づく。
    """
    d = datetime.fromtimestamp(epoch, timezone.utc)
    y, m = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
    return datetime(y, m, 1, tzinfo=timezone.utc).timestamp()


def append_row(row):
    """credits.jsonl へ 1 行追記し、肥大していれば切り詰める（flock 下）。"""
    line = json.dumps(row, ensure_ascii=False) + "\n"
    try:
        import fcntl
        with open(LOCK, "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            with open(OUT, "a", encoding="utf-8") as f:
                f.write(line)
            _prune()
    except ImportError:
        with open(OUT, "a", encoding="utf-8") as f:   # fcntl 非対応環境は排他なし
            f.write(line)


def _prune():
    try:
        with open(OUT, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return
    if len(lines) <= MAX_LINES:
        return
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(lines[-KEEP_LINES:])
    os.replace(tmp, OUT)


def main():
    os.makedirs(TP_DIR, exist_ok=True)
    now_epoch = datetime.now().timestamp()

    token = access_token(now_epoch)
    if token is None:
        return
    body = fetch_usage(token)
    if not isinstance(body, dict):
        return

    extra = body.get("extra_usage")
    if not isinstance(extra, dict):
        return                       # extra usage 非対応プラン/未提供
    enabled = extra.get("is_enabled")      # 枠そのものの有無（金額とは独立）
    used, limit = extra.get("used_credits"), extra.get("monthly_limit")
    try:
        used = None if used is None else round(float(used))
        limit = None if limit is None else round(float(limit))
    except (ValueError, TypeError):
        used = limit = None

    row = {"ts": int(now_epoch), "m1r": int(next_month_start(now_epoch))}
    if used is not None and limit is not None:
        row["used"], row["limit"] = used, limit
    elif enabled is not False:
        return      # 金額が取れず、枠の有無も分からない行は書かない
    if isinstance(enabled, bool):
        row["en"] = enabled
    append_row(row)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:   # 取得失敗を statusline 等に波及させない
        print(f"credits-fetch: {e}", file=sys.stderr)
    sys.exit(0)
