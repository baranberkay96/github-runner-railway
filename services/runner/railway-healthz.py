#!/usr/bin/env python3
"""Liveness endpoint for Railway's healthcheck: GET /healthz on $PORT.

The runner dials out to GitHub and serves nothing, so this tiny server only
tells Railway that the container is up. It always answers 200 while the
supervisor script runs, also when the runner is not configured yet: a
missing token must not fail the deploy (the log says what to set). The body
is the runner's current state, written by railway-runner to STATE_FILE.
"""
import http.server
import os
import socket

STATE_FILE = "/tmp/railway-runner-state"
DEFAULT_PORT = 8080


def port() -> int:
    value = os.environ.get("PORT", "")
    if value.isdigit() and 1 <= int(value) <= 65535:
        return int(value)
    return DEFAULT_PORT


def state() -> str:
    try:
        with open(STATE_FILE, encoding="utf-8") as handle:
            return handle.read(200).strip() or "starting"
    except OSError:
        return "starting"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "railway-runner-healthz"
    sys_version = ""

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        if self.path.split("?", 1)[0] not in ("/healthz", "/"):
            self.send_error(404)
            return
        body = f"ok {state()}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_HEAD = do_GET

    def log_message(self, *args) -> None:  # healthchecks would flood the deploy log
        return


class DualStackServer(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main() -> None:
    try:
        server = DualStackServer(("::", port()), Handler)
    except OSError:  # no IPv6 in this container
        server = http.server.ThreadingHTTPServer(("0.0.0.0", port()), Handler)
        server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
