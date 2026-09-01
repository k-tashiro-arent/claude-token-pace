#!/usr/bin/env python3
"""Codex のレート枠を app-server から取得して codex.jsonl に追記する。

rollout ログ($CODEX_HOME/sessions/**/rollout-*.jsonl)に rate_limits が載るのは
会話が発生したときだけで、会話をしない期間は codex-scan.py では現在値が取れない。
TUI の /status は会話ではなく app-server の JSON-RPC メソッド
account/rateLimits/read を叩いており、その結果はディスクに残らない
(codex-tui 0.148.0 のログで確認)。ここでは /status と同じ経路を直接叩く。

- 取得 : `codex app-server`(既定で stdio の JSON-RPC)に initialize →
         account/rateLimits/read を投げ、応答から used%/窓の長さ/リセット時刻だけを取る。
         会話は発生しないのでトークンを消費しない(実測 約1秒)。
- 出力 : $TOKEN_PACE_DIR/codex.jsonl  codex-scan.py と同じスキーマ
           {ts, u, w, r}        primary
           {..., u2, w2, r2}    secondary がある場合のみ追加
         同じファイルを 2 つのプロセスが書くのでロックは codex-scan.py と共有する。
- 失敗 : 何が起きても exit 0(statusLine / サンプリングに波及させない)。
"""

import json
import os
import select
import subprocess
import sys
import time

TP_DIR = os.path.expanduser(os.environ.get("TOKEN_PACE_DIR") or "~/.claude/token-pace")
OUT = os.path.join(TP_DIR, "codex.jsonl")
LOCK = os.path.join(TP_DIR, ".codex.lock")   # codex-scan.py と同じ(同じファイルを書くため)

CODEX_BIN = os.environ.get("CODEX_BIN") or "codex"
TIMEOUT = 20           # 起動から応答までの上限(実測 約1秒)
MAX_LINES = 20000      # 肥大時はこの行数までに prune
KEEP_LINES = 12000     # prune 後に残す行数

REQS = (
    {"jsonrpc": "2.0", "id": 1, "method": "initialize",
     "params": {"clientInfo": {"name": "claude-token-pace", "version": "1"}}},
    {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}},
)


def _stop(proc):
    """app-server を確実に終わらせる(stdin を閉じただけでは応答前に落ちる)。"""
    for close in (proc.stdin.close, proc.terminate):
        try:
            close()
        except OSError:
            pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
            proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            pass


def _read_response(proc, want_id, deadline):
    """id=want_id の応答を返す。時間切れ・EOF・異常終了なら None。

    通知(実測では configWarning が来る)と非 JSON 行は読み飛ばす。
    """
    buf = b""
    while True:
        left = deadline - time.time()
        if left <= 0:
            return None
        ready, _, _ = select.select([proc.stdout], [], [], min(0.5, left))
        if not ready:
            if proc.poll() is not None:
                return None                  # 応答を返さずに終了した
            continue
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            return None                      # EOF
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if isinstance(msg, dict) and msg.get("id") == want_id:
                return msg


def fetch_rate_limits():
    """app-server から rateLimits のスナップショットを取る。失敗したら None。"""
    try:
        proc = subprocess.Popen(
            [CODEX_BIN, "app-server"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, bufsize=0,
        )
    except (OSError, ValueError):
        return None                          # codex が入っていない環境
    msg = None
    try:
        for req in REQS:
            proc.stdin.write((json.dumps(req) + "\n").encode("utf-8"))
        proc.stdin.flush()
        msg = _read_response(proc, 2, time.time() + TIMEOUT)
    except OSError:
        msg = None
    finally:
        _stop(proc)
    return msg.get("result") if isinstance(msg, dict) else None


def snapshot(result):
    """従来互換の単一バケット rateLimits を優先し、無ければ limit_id=codex を使う。"""
    if not isinstance(result, dict):
        return None
    snap = result.get("rateLimits")
    if isinstance(snap, dict):
        return snap
    by_id = result.get("rateLimitsByLimitId")
    if isinstance(by_id, dict) and isinstance(by_id.get("codex"), dict):
        return by_id["codex"]
    return None


def window(d):
    """primary / secondary から (used%, 窓の分, resets_at) を取る。欠けていれば None。"""
    if not isinstance(d, dict):
        return None
    u, w, r = d.get("usedPercent"), d.get("windowDurationMins"), d.get("resetsAt")
    if u is None or w is None or r is None:
        return None
    try:
        return float(u), int(w), int(r)
    except (ValueError, TypeError):
        return None


def append_row(row):
    """codex.jsonl へ 1 行追記し、肥大していれば切り詰める(flock 下)。"""
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
    snap = snapshot(fetch_rate_limits())
    if snap is None:
        return
    p = window(snap.get("primary"))
    if p is None:
        return       # 枠到達などで窓が返らない期間は記録しない(codex-scan.py と同じ規律)
    row = {"ts": int(time.time()), "u": p[0], "w": p[1], "r": p[2]}
    s = window(snap.get("secondary"))
    if s is not None:
        row["u2"], row["w2"], row["r2"] = s
    append_row(row)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:   # 取得失敗を statusline 等に波及させない
        print(f"codex-fetch: {e}", file=sys.stderr)
    sys.exit(0)
