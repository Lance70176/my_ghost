"""Local HTTP API (127.0.0.1 only).

    POST /hook/permission     hook payload -> blocks -> {"behavior": ...}
    POST /hook/event          Notification / Stop / UserPromptSubmit / SessionEnd
    GET  /api/state?since=N   {version, pending, sessions}; long-polls up to
                              `wait` seconds while version == since
    POST /api/decisions/<id>  {"action": allow|deny|always|confirm|cancel,
                               "by": "myghost"|"web", "message": "..."}
    GET  /api/health

    GET  /api/assistants                       every project assistant's status
    GET  /api/assistants/<p>/chat?since=N&wait=25
    POST /api/assistants/<p>/messages          {"text": "...", "source": "myghost"}
    POST /api/assistants/<p>/stop              interrupt the current turn
    POST /api/assistants/<p>/start
    POST /assistant-tools/<name>               {"project": p, "args": {...}} (ghost-tools)

Remote clients (MyGhost on another Mac, over Tailscale) must also send
`X-Ghost-Token` matching config `remote.token`; loopback needs no token.
The hook and tool endpoints are loopback-only.

Every POST must carry `X-Ghost: 1`. A browser can't add a custom header to a
cross-origin request without a CORS preflight we never answer, so a web page
can't click "allow" on the user's behalf through localhost.
"""

from __future__ import annotations

import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .broker import Broker, log

DECIDE = re.compile(r"^/api/decisions/([0-9a-f]{8})$")
ASSISTANT = re.compile(r"^/api/assistants/([A-Za-z0-9_.-]+)/(chat|messages|stop|start)$")
TOOL = re.compile(r"^/assistant-tools/([a-z_]+)$")
WORKERS = re.compile(r"^/api/projects/([A-Za-z0-9_.-]+)/workers$")
LOOPBACK = ("127.0.0.1", "::1", "::ffff:127.0.0.1")


def make_handler(broker: Broker, assistants=None, tools=None, remote_token: str = ""):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # quiet; broker logs what matters
            pass

        def _send(self, code: int, body) -> None:
            data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0:
                return {}
            return json.loads(self.rfile.read(min(n, 2_000_000)) or b"{}")

        def _state(self) -> dict:
            return {"version": broker.version, "pending": broker.list_pending(),
                    "sessions": broker.list_sessions(), "surfaces": broker.surfaces()}

        def _local(self) -> bool:
            return self.client_address[0] in LOOPBACK

        def _allowed(self) -> bool:
            if self._local():
                return True
            return bool(remote_token) and self.headers.get("X-Ghost-Token") == remote_token

        def do_GET(self):
            if not self._allowed():
                return self._send(401, {"error": "token required"})
            try:
                self._get()
            except Exception as e:
                log(f"http: GET {self.path} failed: {e!r}")
                self._send(500, {"error": str(e)})

        def do_POST(self):
            if not self._allowed():
                return self._send(401, {"error": "token required"})
            try:
                self._post()
            except Exception as e:
                log(f"http: POST {self.path} failed: {e!r}")
                self._send(500, {"error": str(e)})

        def _get(self):
            u = urlparse(self.path)
            q = parse_qs(u.query)
            if u.path == "/api/health":
                return self._send(200, {"ok": True, "version": broker.version,
                                        "surfaces": broker.surfaces()})
            if u.path == "/api/projects":
                return self._send(200, {"projects": broker.list_projects()})
            if u.path == "/api/decisions":
                project = (q.get("project") or [""])[0] or None
                limit = min(int((q.get("limit") or ["200"])[0]), 1000)
                return self._send(200, {"decisions": broker.list_decisions(project, limit)})
            if u.path == "/api/state":
                client = (q.get("client") or [""])[0]
                if client in ("myghost", "web"):
                    broker.seen(client)
                since = int((q.get("since") or ["-1"])[0])
                wait = min(float((q.get("wait") or ["0"])[0]), 55)
                if wait > 0 and since == broker.version:
                    broker.wait_change(since, wait)
                return self._send(200, self._state())
            if u.path == "/api/assistants" and assistants:
                return self._send(200, {"assistants": assistants.list()})
            m = WORKERS.match(u.path)
            if m:
                from .tools import list_jobs
                p = broker.projects.get(m.group(1))
                own = assistants.get(p.name).meta.get("session_id", "") if assistants else ""
                return self._send(200, {"workers": list_jobs(p.paths, exclude_session=own)})
            m = ASSISTANT.match(u.path)
            if m and m.group(2) == "chat" and assistants:
                since = int((q.get("since") or ["0"])[0])
                wait = min(float((q.get("wait") or ["0"])[0]), 55)
                return self._send(200, assistants.chat(m.group(1), since, wait))
            self._send(404, {"error": "not found"})

        def _post(self):
            if self.headers.get("X-Ghost") != "1":
                return self._send(403, {"error": "missing X-Ghost header"})
            u = urlparse(self.path)
            try:
                body = self._body()
            except ValueError:
                return self._send(400, {"error": "bad json"})
            if u.path in ("/hook/permission", "/hook/event") or u.path.startswith("/assistant-tools/"):
                if not self._local():
                    return self._send(403, {"error": "local only"})
            if u.path == "/hook/permission":
                return self._send(200, broker.request_permission(body))
            if u.path == "/hook/event":
                broker.hook_event(body)
                return self._send(200, {"ok": True})
            m = TOOL.match(u.path)
            if m and tools:
                text = tools.call(str(body.get("project", "")), m.group(1), body.get("args") or {})
                return self._send(200, {"text": text})
            m = ASSISTANT.match(u.path)
            if m and assistants:
                name, verb = m.groups()
                a = assistants.get(name)
                if verb == "messages":
                    text = str(body.get("text") or "").strip()
                    if not text:
                        return self._send(400, {"error": "empty"})
                    src = body.get("source") if body.get("source") in ("myghost", "web") else "myghost"
                    a.send(text[:20000], src)
                    return self._send(200, {"ok": True, "seq": a.seq})
                if verb == "stop":
                    return self._send(200, {"ok": a.interrupt()})
                if verb == "start":
                    a.start()
                    return self._send(200, {"ok": True})
            m = DECIDE.match(u.path)
            if m:
                by = body.get("by") if body.get("by") in ("myghost", "web") else "myghost"
                ok, why = broker.decide(m.group(1), str(body.get("action", "")), by,
                                        str(body.get("message") or "")[:500])
                return self._send(200 if ok else 409, {"ok": ok, "message": why})
            self._send(404, {"error": "not found"})

    return Handler


def serve(broker: Broker, host: str, port: int, assistants=None, tools=None,
          remote_token: str = "") -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((host, port), make_handler(broker, assistants, tools, remote_token))
    httpd.daemon_threads = True
    log(f"http: listening on {host}:{port}")
    return httpd
