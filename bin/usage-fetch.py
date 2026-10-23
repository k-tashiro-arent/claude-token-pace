#!/usr/bin/env python3
"""Claude の 5h/7d レート枠を pace.jsonl に 1 行追記する。取り方は 2 つ:

- 既定      : API（Claude Code 自身が使うのと同じ GET /api/oauth/usage）から口座単位の現在値を取る。
              セッションによるばらつきが無く、Claude Code が動いていない間も取得できる。
- --statusline : 標準入力に来た statusLine の JSON の rate_limits を記録する（src:"statusline"）。
              API が 429 で休んでいる間も Claude Code を使っていれば記録が途切れない。
              API の間引き・429 の休止は見ない（API を叩かないため）。rate_limits は
              セッションごとの持ち回りで、再開直後などに古いスナップショット（例: h5=0 / d7=100）が
              来ることがある。記録は無加工で行い、古い行は pace-json.py の _stale が弾く。

- 認証 : $CLAUDE_CONFIG_DIR(既定 ~/.claude)/.credentials.json の claudeAiOauth.accessToken
         （macOS はこのファイルが無く Keychain に入るので、security コマンドで読む）
         を読むだけ（credits-fetch.py と同じ。refresh は Claude Code 本体に任せる）。
- 出力 : $TOKEN_PACE_DIR/pace.jsonl  {ts, h5, h5r, d7, d7r, cost, sid, src:"api"|"statusline"}
         h5r/d7r は epoch 秒（pace-json.py の鮮度判定が数値を前提にするため）。
- 間引き: $TOKEN_PACE_DIR/.last_usage で INTERVAL 秒に 1 回だけ取得する。短い間隔で叩くと
         API が 429(rate_limit_error) を返すため（実測: 30 秒間隔で発生）、定期実行の間隔と
         合わせて下限を設ける。429 を受けたら .usage_backoff まで取得を止める。
- 終了 : 0=追記した / 2=間引き中で何もしない / 1=取得できなかった
         --statusline のとき: 0=追記した / 2=rate_limits が無い（API 応答前など）/ 1=JSON を読めない

環境変数（試験用）: TOKEN_PACE_USAGE_URL でエンドポイントを差し替えられる。
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
OUT = os.path.join(TP_DIR, "pace.jsonl")
LOCK = os.path.join(TP_DIR, ".lock")          # pace.jsonl を切り詰める pace-json.py と同じ排他
STAMP = os.path.join(TP_DIR, ".last_usage")
BACKOFF = os.path.join(TP_DIR, ".usage_backoff")

USAGE_URL = os.environ.get("TOKEN_PACE_USAGE_URL") or "https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA = "oauth-2025-04-20"
TIMEOUT = 5
INTERVAL = 240         # 秒。定期実行は 5 分間隔なので、その手前で止める下限
BACKOFF_SEC = 900      # 429 を受けたらこの秒数は取りに行かない


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



def access_token():
    """有効な OAuth アクセストークン。無い/期限切れなら None。"""
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
        if exp is not None and float(exp) / 1000.0 <= datetime.now(timezone.utc).timestamp():
            return None              # 期限切れ。本体がリフレッシュするまで待つ
    except (ValueError, TypeError):
        pass
    return token


def fetch(token, now):
    """GET /api/oauth/usage。失敗したら None。429 なら BACKOFF_SEC の間は諦める印を置く。"""
    headers = {"Content-Type": "application/json", "anthropic-beta": OAUTH_BETA}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(USAGE_URL, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
            return json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if e.code == 429:                      # 叩きすぎ。しばらく取りに行かない
            try:
                with open(BACKOFF, "w", encoding="utf-8") as f:
                    f.write(str(now + BACKOFF_SEC))
            except OSError:
                pass
        return None
    except (urllib.error.URLError, OSError, ValueError):
        return None


def _epoch(v):
    """resets_at（ISO8601 文字列 or 数値）を epoch 秒の int にする。駄目なら None。"""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if not isinstance(v, str):
        return None
    try:
        return int(datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def _window(d, key):
    """five_hour / seven_day ブロックから (used%, reset epoch) を取り出す。"""
    blk = d.get(key)
    if not isinstance(blk, dict):
        return None, None
    used = blk.get("utilization")
    try:
        used = round(float(used), 1)
    except (ValueError, TypeError):
        used = None
    return used, _epoch(blk.get("resets_at"))


def backing_off(now):
    """429 を受けた直後か。"""
    try:
        with open(BACKOFF, "r", encoding="utf-8") as f:
            return now < int(float(f.read().strip() or 0))
    except (OSError, ValueError):
        return False


def throttled(now):
    """前回取得から INTERVAL 秒経っていなければ True。経っていれば印を更新する。"""
    last = 0
    try:
        with open(STAMP, "r", encoding="utf-8") as f:
            last = int(float(f.read().strip() or 0))
    except (OSError, ValueError):
        last = 0
    if now - last < INTERVAL:
        return True
    try:
        with open(STAMP, "w", encoding="utf-8") as f:
            f.write(str(now))
    except OSError:
        pass
    return False


def append_row(row):
    """pace.jsonl へ 1 行追記する（pace-json.py と同じ .lock の下で）。"""
    line = json.dumps(row, ensure_ascii=False) + "\n"
    try:
        import fcntl
        with open(LOCK, "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            with open(OUT, "a", encoding="utf-8") as f:
                f.write(line)
    except ImportError:
        with open(OUT, "a", encoding="utf-8") as f:   # fcntl 非対応環境は排他なし
            f.write(line)


def _sl_window(rl, key):
    """statusLine の rate_limits.five_hour / seven_day から (used%, reset epoch) を取り出す。"""
    blk = rl.get(key) if isinstance(rl, dict) else None
    if not isinstance(blk, dict):
        return None, None
    used = blk.get("used_percentage")
    try:
        used = round(float(used), 1)
    except (ValueError, TypeError):
        used = None
    return used, _epoch(blk.get("resets_at"))


def record_statusline(text, now):
    """statusLine の JSON から 1 行追記する。終了コードは main と同じ規約。"""
    if not text.strip():
        return 2                      # 何も来ていない（0.4.1 以前のラッパーは </dev/null で蹴る）
    try:
        d = json.loads(text)
    except ValueError:
        return 1
    if not isinstance(d, dict):
        return 1
    rl = d.get("rate_limits")
    h5, h5r = _sl_window(rl, "five_hour")
    d7, d7r = _sl_window(rl, "seven_day")
    if h5 is None and d7 is None:
        return 2                      # まだ rate_limits が載っていない（API 応答前など）
    cost = d.get("cost")
    cost = cost.get("total_cost_usd") if isinstance(cost, dict) else None
    sid = d.get("session_id") or d.get("sessionId")
    append_row({"ts": now, "h5": h5, "h5r": h5r, "d7": d7, "d7r": d7r,
                "cost": cost, "sid": sid, "src": "statusline"})
    return 0


def main():
    now = int(datetime.now(timezone.utc).timestamp())
    try:
        os.makedirs(TP_DIR, exist_ok=True)
    except OSError:
        return 1
    if sys.argv[1:] == ["--statusline"]:
        return record_statusline(sys.stdin.read(), now)
    if backing_off(now) or throttled(now):
        return 2
    token = access_token()
    if token is None and USAGE_URL.startswith("https://"):
        return 1          # 認証できないのに叩かない（試験用の file:// は通す）
    data = fetch(token, now)
    if not isinstance(data, dict):
        return 1
    h5, h5r = _window(data, "five_hour")
    d7, d7r = _window(data, "seven_day")
    if h5 is None and d7 is None:
        return 1                      # 枠が 1 つも読めない応答は記録しない
    append_row({"ts": now, "h5": h5, "h5r": h5r, "d7": d7, "d7r": d7r,
                "cost": None, "sid": None, "src": "api"})
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:                 # 何が起きても呼び出し側に波及させない
        sys.exit(1)
