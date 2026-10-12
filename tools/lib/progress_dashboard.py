"""Serve a self-refreshing progress page for a long-running script.

Usage: python3 -I tools/lib/progress_dashboard.py STATUS_JSON TITLE [--port N] [--open]

STATUS_JSON is rewritten by the running script. It must hold "state"
("running", "done", "failed" or "cancelled"); every "done_X"/"total_X" pair
is drawn as a progress bar and every other field is listed. The page reloads
every 2 seconds. The server stops 5 minutes after the state leaves "running",
or when killed.
"""
from __future__ import annotations

import argparse
import html
import http.server
import json
import subprocess
import sys
import threading
import time

DEFAULT_PORT = 8765
REFRESH_SECONDS = 2
LINGER_AFTER_FINISH_SECONDS = 300
POLL_SECONDS = 2


def read_status(path: str) -> dict:
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {"state": "starting"}


def render(title: str, status: dict) -> str:
    bars, rows = [], []
    for key, value in status.items():
        if key.startswith("done_") and f"total_{key[5:]}" in status:
            total = status[f"total_{key[5:]}"] or 0
            percent = 100.0 * value / total if total else 0.0
            bars.append(f"<p>{html.escape(key[5:])}: {value} / {total} ({percent:.1f}%)</p>"
                        f"<progress max='100' value='{percent:.1f}'></progress>")
        elif not key.startswith("total_"):
            rows.append(f"<tr><th>{html.escape(str(key))}</th><td>{html.escape(str(value))}</td></tr>")
    return (f"<!doctype html><meta http-equiv='refresh' content='{REFRESH_SECONDS}'>"
            f"<title>{html.escape(title)}</title>"
            "<style>body{font:15px -apple-system,sans-serif;margin:2em}progress{width:100%;height:1.4em}"
            "th{text-align:left;padding-right:1em}</style>"
            f"<h1>{html.escape(title)}</h1>{''.join(bars)}<table>{''.join(rows)}</table>")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("status_json")
    parser.add_argument("title")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args(argv)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 (http.server API)
            body = render(args.title, read_status(args.status_json)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args: object) -> None:
            return

    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    except OSError as error:
        print(f"WARN: dashboard not started on port {args.port}: {error}", file=sys.stderr)
        return 1
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{args.port}/"
    print(f"dashboard: {url}", file=sys.stderr)
    if args.open:
        subprocess.run(["/usr/bin/open", url], check=False)
    finished_at = None
    while True:
        time.sleep(POLL_SECONDS)
        if read_status(args.status_json).get("state") in ("done", "failed", "cancelled"):
            finished_at = finished_at or time.time()
            if time.time() - finished_at > LINGER_AFTER_FINISH_SECONDS:
                server.shutdown()
                return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
