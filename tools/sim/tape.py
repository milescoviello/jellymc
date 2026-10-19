#!/usr/bin/env python3
"""A Jellyfin server on tape, for the iOS simulator on CI, where no real one can run.

    tape.py record --upstream http://localhost:8096 --port 8097 --dir tools/sim/tape
        A proxy in front of a real (test) server: whatever an app asks through it is
        passed on, and the answer kept. Point the Linux app at it and browse.

    tape.py serve --dir tools/sim/tape --port 8096
        Answers from the tape. A request is matched by method, path and query (in any
        order); failing that, by method and path with the closest query; an image by its
        item and kind alone, since each app asks for its own sizes. Anything else that
        writes (progress, capabilities) gets 204, and the rest 404, each miss logged.

Only ever record a test server: what is on the tape is committed.
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

TOKEN = "tape-token"


def key_of(method, path, query):
    pairs = sorted(urllib.parse.parse_qsl(query, keep_blank_values=True))
    return method.upper(), path.lower(), pairs


class Tape:
    def __init__(self, folder):
        self.folder = folder
        self.index_file = os.path.join(folder, "index.json")
        self.lock = threading.Lock()
        os.makedirs(os.path.join(folder, "bodies"), exist_ok=True)
        self.entries = []
        if os.path.exists(self.index_file):
            with open(self.index_file) as f:
                self.entries = json.load(f)

    def add(self, method, path, query, status, content_type, body):
        digest = hashlib.sha1(body).hexdigest()[:16]
        name = digest + (".json" if "json" in content_type else ".bin")
        with open(os.path.join(self.folder, "bodies", name), "wb") as f:
            f.write(body)
        _, lpath, pairs = key_of(method, path, query)
        entry = {"method": method.upper(), "path": lpath, "query": pairs, "status": status, "type": content_type, "body": name}
        with self.lock:
            self.entries = [e for e in self.entries if not (e["method"] == entry["method"] and e["path"] == lpath and e["query"] == pairs)]
            self.entries.append(entry)
            with open(self.index_file, "w") as f:
                json.dump(self.entries, f, indent=0, sort_keys=True)

    def find(self, method, path, query):
        method, lpath, pairs = key_of(method, path, query)
        same = [e for e in self.entries if e["method"] == method and e["path"] == lpath]
        exact = [e for e in same if [tuple(p) for p in e["query"]] == pairs]
        if exact:
            return exact[-1]
        if same:
            wanted = set(pairs)
            return max(same, key=lambda e: len(wanted & {tuple(p) for p in e["query"]}))
        # Images: /items/{id}/images/{kind}[/{index}], at whatever size was kept.
        match = re.match(r"(/items/[^/]+/images/[^/]+)", lpath)
        if match and method == "GET":
            prefix = match.group(1)
            for e in self.entries:
                if e["path"].startswith(prefix):
                    return e
        return None

    def body(self, entry):
        with open(os.path.join(self.folder, "bodies", entry["body"]), "rb") as f:
            return f.read()


def scrub(path, body):
    """The sign-in's token is the test server's; the tape's is a stand-in."""
    if path.lower().endswith("/users/authenticatebyname"):
        try:
            data = json.loads(body)
            data["AccessToken"] = TOKEN
            return json.dumps(data).encode()
        except ValueError:
            pass
    return body


def make_handler(tape, upstream, log):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def handle_any(self):
            length = int(self.headers.get("Content-Length") or 0)
            request_body = self.rfile.read(length) if length else b""
            parsed = urllib.parse.urlsplit(self.path)
            if upstream:
                self.forward(parsed, request_body)
            else:
                self.replay(parsed)

        def forward(self, parsed, request_body):
            headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection", "accept-encoding", "content-length", "upgrade")}
            if self.headers.get("Upgrade"):
                self.reply(404, "text/plain", b"no sockets on tape")
                return
            request = urllib.request.Request(upstream + self.path, data=request_body or None, method=self.command, headers=headers)
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    status, content_type, body = response.status, response.headers.get("Content-Type", ""), response.read()
            except urllib.error.HTTPError as error:
                status, content_type, body = error.code, error.headers.get("Content-Type", ""), error.read()
            except Exception as error:  # noqa: BLE001
                self.reply(502, "text/plain", str(error).encode())
                return
            if status < 300:
                tape.add(self.command, parsed.path, parsed.query, status, content_type, scrub(parsed.path, body))
            log.write(f"{self.command} {status} {self.path}\n")
            log.flush()
            self.reply(status, content_type, body)

        def replay(self, parsed):
            if self.headers.get("Upgrade"):
                self.reply(404, "text/plain", b"no sockets on tape")
                return
            entry = tape.find(self.command, parsed.path, parsed.query)
            if entry:
                self.reply(entry["status"], entry["type"], tape.body(entry))
                return
            status = 204 if self.command in ("POST", "DELETE") else 404
            log.write(f"MISS {self.command} {status} {self.path}\n")
            log.flush()
            self.reply(status, "text/plain", b"")

        def reply(self, status, content_type, body):
            self.send_response(status)
            if body or status != 204:
                self.send_header("Content-Type", content_type or "application/octet-stream")
                self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body and self.command != "HEAD":
                self.wfile.write(body)

        do_GET = do_POST = do_DELETE = do_HEAD = do_PUT = handle_any

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["record", "serve"])
    parser.add_argument("--dir", required=True)
    parser.add_argument("--port", type=int, default=8096)
    parser.add_argument("--upstream")
    parser.add_argument("--log", default="-")
    args = parser.parse_args()
    if args.mode == "record" and not args.upstream:
        sys.exit("record needs --upstream")
    tape = Tape(args.dir)
    log = sys.stderr if args.log == "-" else open(args.log, "a")
    server = http.server.ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(tape, args.upstream if args.mode == "record" else None, log))
    print(f"{args.mode} on :{args.port}, {len(tape.entries)} on tape", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
