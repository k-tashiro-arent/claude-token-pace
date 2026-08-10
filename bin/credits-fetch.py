#!/usr/bin/env python3
"""月次クレジット枠(extra usage)を取得して credits.jsonl に追記する。

statusLine の JSON に載るレート枠は 5h/7d の used%/resets_at だけで、月次のクレジット
消費（プラン枠を超えた分の支出）は含まれない。そのため Claude Code 自身が使うのと同じ
エンドポイント GET /api/oauth/usage から取得する。

- 認証 : $CLAUDE_CONFIG_DIR(既定 ~/.claude)/.credentials.json の claudeAiOauth.accessToken
         を読むだけ。期限切れ・不在なら何もしない（refresh は Claude Code 本体に任せる。
         ここで refresh すると refreshToken のローテーションで本体の認証を壊しうる）。
- 出力 : $TOKEN_PACE_DIR/credits.jsonl  {ts, used, limit, m1r}
         used/limit は API の minor 単位そのまま（USD なら cent）。
         m1r = 翌月1日 00:00(ローカル) の epoch＝この枠のリセット時刻。
- 失敗 : 何が起きても exit 0（statusLine / サンプリングに波及させない）。
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime

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


def access_token(now_epoch):
    """有効な OAuth アクセストークンを返す。無い/期限切れなら None。"""
    try:
        with open(CRED, "r", encoding="utf-8") as f:
            cred = json.load(f)
    except (OSError, ValueError):
        return None          # macOS の Keychain 保管などファイルが無い環境では機能しない
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
    """epoch を含む月の翌月 1 日 00:00(ローカル) の epoch。"""
    d = datetime.fromtimestamp(epoch)
    y, m = (d.year + 1, 1) if d.month == 12 else (d.year, d.month + 1)
    return datetime(y, m, 1).timestamp()


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
    used, limit = extra.get("used_credits"), extra.get("monthly_limit")
    if used is None or limit is None:
        return
    try:
        used, limit = round(float(used)), round(float(limit))
    except (ValueError, TypeError):
        return

    append_row({"ts": int(now_epoch), "used": used, "limit": limit,
                "m1r": int(next_month_start(now_epoch))})


if __name__ == "__main__":
    try:
        main()
    except Exception as e:   # 取得失敗を statusline 等に波及させない
        print(f"credits-fetch: {e}", file=sys.stderr)
    sys.exit(0)
