#!/usr/bin/env python3
"""Codex CLI のレート枠を rollout ログから収集して codex.jsonl に追記する。

Codex には statusLine のような hook が無いため、CLI が書くセッションログ
($CODEX_HOME(既定 ~/.codex)/sessions/YYYY/MM/DD/rollout-*.jsonl) を追いかける。
各 token_count イベントに、その応答で返ってきたレート枠がそのまま入っている。

- 読む : rollout-*.jsonl の event_msg/token_count レコードのみ。取り出すのは
         timestamp と rate_limits の数値だけで、**会話本文・ツール出力には
         一切触れない**（読み取りもコピーもしない）。
- 出力 : $TOKEN_PACE_DIR/codex.jsonl
           {ts, u, w, r}        primary  = used%, 窓の長さ(分), resets_at
           {..., u2, w2, r2}    secondary がある場合のみ追加
- 増分 : $TOKEN_PACE_DIR/.codex_scan.json にファイルごとの読み込み済みバイト数を
         記録し、追記分だけを読む（ログは追記専用なので末尾差分で足りる）。
         全走査は初回のみ。初回も MAX_AGE_DAYS より古いファイルは対象外。
- 失敗 : 何が起きても exit 0（statusLine / サンプリングに波及させない）。
"""

import json
import os
import sys
import time
from datetime import datetime

TP_DIR = os.path.expanduser(os.environ.get("TOKEN_PACE_DIR") or "~/.claude/token-pace")
CODEX_DIR = os.path.expanduser(os.environ.get("CODEX_HOME") or "~/.codex")
SESSIONS = os.path.join(CODEX_DIR, "sessions")
OUT = os.path.join(TP_DIR, "codex.jsonl")
STATE = os.path.join(TP_DIR, ".codex_scan.json")
LOCK = os.path.join(TP_DIR, ".codex.lock")

MAX_AGE_DAYS = 60      # 初回バックフィルで遡る上限
MAX_LINES = 20000      # 肥大時はこの行数までに prune
KEEP_LINES = 12000     # prune 後に残す行数


def load_state():
    try:
        with open(STATE, "r", encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        return {}
    files = st.get("files")
    return files if isinstance(files, dict) else {}


def save_state(files):
    tmp = f"{STATE}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"files": files}, f)
        os.replace(tmp, STATE)
    except OSError:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def _epoch(s):
    if not isinstance(s, str):
        return None
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def _limit(d):
    """rate_limits.primary / .secondary から (used%, 窓の分, resets_at) を取る。"""
    if not isinstance(d, dict):
        return None
    u, w, r = d.get("used_percent"), d.get("window_minutes"), d.get("resets_at")
    if u is None or w is None or r is None:
        return None
    try:
        return float(u), int(w), int(r)
    except (ValueError, TypeError):
        return None


def extract(line):
    """1 行から数値だけを取り出す。該当しない行は None（本文は保持しない）。"""
    try:
        rec = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return None
    payload = rec.get("payload")
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None
    rl = payload.get("rate_limits")
    if not isinstance(rl, dict):
        return None
    ts = _epoch(rec.get("timestamp"))
    p = _limit(rl.get("primary"))
    if ts is None or p is None:
        return None
    row = {"ts": ts, "u": p[0], "w": p[1], "r": p[2]}
    s = _limit(rl.get("secondary"))
    if s is not None:
        row["u2"], row["w2"], row["r2"] = s
    return row


def read_new(path, off):
    """off 以降の追記分から行を取り出し、(新しい off, rows) を返す。"""
    try:
        with open(path, "rb") as f:
            f.seek(off)
            buf = f.read()
    except OSError:
        return None, []
    cut = buf.rfind(b"\n")
    if cut < 0:
        return off, []            # まだ 1 行も完成していない
    rows = []
    for line in buf[:cut + 1].splitlines():
        if b'"token_count"' not in line or b'"rate_limits"' not in line:
            continue              # 本文行はここで捨てる（parse もしない）
        row = extract(line)
        if row:
            rows.append(row)
    return off + cut + 1, rows


def scan():
    """rollout を増分走査して (rows, 新しい state) を返す。"""
    known = load_state()
    cutoff = time.time() - MAX_AGE_DAYS * 86400
    files, rows = {}, []
    for root, dirs, names in os.walk(SESSIONS):
        dirs.sort()
        for name in sorted(names):
            if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                continue
            path = os.path.join(root, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            off = known.get(path)
            if off is None:
                if st.st_mtime < cutoff:
                    continue      # 初回バックフィルの範囲外
                off = 0
            if not isinstance(off, int) or off > st.st_size:
                off = 0           # 切り詰め/入れ替えが起きたら読み直す
            if off == st.st_size:
                files[path] = off
                continue          # 追記なし
            new_off, got = read_new(path, off)
            if new_off is None:
                continue          # 消えたファイルは state からも落とす
            files[path] = new_off
            rows.extend(got)
    return rows, files


def append_rows(rows):
    if not rows:
        return
    rows.sort(key=lambda r: r["ts"])
    body = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows)
    try:
        import fcntl
        with open(LOCK, "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            with open(OUT, "a", encoding="utf-8") as f:
                f.write(body)
            _prune()
    except ImportError:
        with open(OUT, "a", encoding="utf-8") as f:   # fcntl 非対応環境は排他なし
            f.write(body)


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
    if not os.path.isdir(SESSIONS):
        return                    # Codex が入っていない環境では何もしない
    os.makedirs(TP_DIR, exist_ok=True)

    # 初回はログ全体を読むため時間がかかる。多重起動すると同じ差分を二重に
    # 取り込むので、取れなければ黙って降りる（次の起動で拾える）。
    try:
        import fcntl
        _lock = open(os.path.join(TP_DIR, ".codex_scan.lock"), "w")  # noqa: SIM115
        try:
            fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return
    except ImportError:
        pass

    rows, files = scan()
    append_rows(rows)
    save_state(files)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:   # 収集失敗を statusline 等に波及させない
        print(f"codex-scan: {e}", file=sys.stderr)
    sys.exit(0)
