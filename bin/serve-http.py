#!/usr/bin/env python3
"""claude-token-pace のローカルビューア配信（127.0.0.1 専用・最小ホワイトリスト）。

`python3 -m http.server` の代替。$TOKEN_PACE_DIR 全体を配信する代わりに index.html と
pace.json だけを返し、Host ヘッダを検証して DNS リバインドを弾く。これにより
pace.jsonl（session_id/cost/使用率）や .orig_statusline（ローカルパス）等は配信されない。

  usage: serve-http.py <port>   # 127.0.0.1:<port> で待ち受け
"""

import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TP_DIR = os.path.expanduser(os.environ.get("TOKEN_PACE_DIR") or "~/.claude/token-pace")

# 配信を許可するパスだけを列挙（それ以外は 404）。
ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/pace.json": ("pace.json", "application/json; charset=utf-8"),
}

# DNS リバインド対策として許可する Host（:port は無視して比較）。
ALLOWED_HOSTS = {"127.0.0.1", "localhost", "::1", "[::1]"}


def host_ok(host):
    """Host ヘッダが localhost/127.0.0.1(:port) のときだけ True。"""
    if not host:
        return False
    h = host
    if h.startswith("["):            # IPv6 リテラル "[::1]:port"
        h = h[: h.find("]") + 1]
    elif ":" in h:                   # "127.0.0.1:port"
        h = h.rsplit(":", 1)[0]
    return h in ALLOWED_HOSTS


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not host_ok(self.headers.get("Host")):
            self.send_error(403, "Forbidden")
            return
        path = self.path.split("?", 1)[0]
        route = ROUTES.get(path)
        if route is None:
            self.send_error(404, "Not Found")
            return
        fpath = os.path.join(TP_DIR, route[0])
        try:
            with open(fpath, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error(404, "Not Found")
            return
        self.send_response(200)
        self.send_header("Content-Type", route[1])
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # アクセスログは出さない（バックグラウンド起動のため）


def main():
    if len(sys.argv) < 2:
        print("usage: serve-http.py <port>", file=sys.stderr)
        sys.exit(2)
    port = int(sys.argv[1])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
