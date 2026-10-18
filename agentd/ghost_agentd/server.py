"""Local HTTP API (127.0.0.1 only).

    POST /hook/permission     hook payload -> blocks -> {"behavior": ...}
    POST /hook/event          Notification / Stop / UserPromptSubmit / SessionEnd
    GET  /api/state?since=N   {version, pending, sessions}; long-polls up to
                              `wait` seconds while version == since
    POST /api/decisions/<id>  {"action": allow|deny|always|confirm|cancel,
                               "by": "myghost"|"web", "message": "..."}
    GET  /api/health
    POST /api/projects/probe  {"token"} -> the bot and the groups it's in
    POST /api/projects        new project assistant (see newproject.py)

    GET  /api/assistants                       every project assistant's status
    GET  /api/assistants/<p>/chat?since=N&wait=25
    POST /api/assistants/<p>/messages          {"text": "...", "source": "myghost"}
    POST /api/assistants/<p>/stop              interrupt the current turn
    POST /api/assistants/<p>/start
    POST /api/uploads?project=P&to=assistant|<job id>&name=N   raw bytes ->
                                               {path, name, kind, size}; pass the
                                               paths as "files" with the message
    GET  /api/assistants/<p>/file?path=...     an attachment (for previews)
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
import mimetypes
import re
import select
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import uploads
from .broker import Broker, log

DECIDE = re.compile(r"^/api/decisions/([0-9a-f]{8})$")
ASSISTANT = re.compile(r"^/api/assistants/([A-Za-z0-9_.-]+)/(chat|messages|stop|start|file)$")
TOOL = re.compile(r"^/assistant-tools/([a-z_]+)$")
HELP = re.compile(r"^/api/help/([0-9a-f]{6})$")
WORKERS = re.compile(r"^/api/projects/([A-Za-z0-9_.-]+)/workers$")
WORKER = re.compile(r"^/api/projects/([A-Za-z0-9_.-]+)/workers/([0-9a-f]{8})/(log|send|remove)$")
LOOPBACK = ("127.0.0.1", "::1", "::ffff:127.0.0.1")


def make_handler(broker: Broker, assistants=None, tools=None, remote_token: str = "", dispatcher=None,
                 helpdesk=None, setup=None):
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

        def _raw(self) -> bytes:
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if 0 < n <= uploads.MAX_BYTES else b""

        def _upload_dir(self, project: str, to: str) -> Path | None:
            """Where an attachment for this reader is kept, or None."""
            p = broker.projects.get(project)
            if p is None:
                return None
            if to == "assistant":
                return assistants.get(p.name).uploads if assistants else None
            from .tools import find_job
            own = assistants.get(p.name).meta.get("session_id", "") if assistants else ""
            job = find_job(p.paths, to, exclude_session=own)
            if job is None or not job.get("cwd"):
                return None
            return Path(job["cwd"]) / uploads.WORKER_DIR

        def _files(self, body: dict, folder: Path | None) -> list[uploads.Attached] | None:
            """The attachments named in a message, all ours; None if any isn't.
            Each is a path, or {"path", "label"} with its "[Image #1]" mark."""
            out = []
            for f in (body.get("files") or [])[:20]:
                path, at = (f.get("path"), uploads.label(f.get("label"))) if isinstance(f, dict) else (f, "")
                p = uploads.inside(str(path or ""), folder) if folder else None
                if p is None:
                    return None
                out.append(uploads.Attached(p, at))
            return out

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0:
                return {}
            return json.loads(self.rfile.read(min(n, 2_000_000)) or b"{}")

        def _state(self) -> dict:
            return {"version": broker.version, "pending": broker.list_pending(),
                    "sessions": broker.list_sessions(), "surfaces": broker.surfaces(),
                    "dispatched": dispatcher.live() if dispatcher else []}

        def _local(self) -> bool:
            return self.client_address[0] in LOOPBACK

        def _client_connected(self) -> bool:
            """Whether the hook that sent this request is still there. A hook
            sends nothing more while it waits, so a readable socket means EOF:
            Claude Code ended it, the request having been answered elsewhere."""
            try:
                readable, _, _ = select.select([self.connection], [], [], 0)
                if not readable:
                    return True
                return self.connection.recv(1, socket.MSG_PEEK) != b""
            except OSError:
                return False

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
            m = HELP.match(u.path)
            if m and helpdesk:
                if not self._local():
                    return self._send(403, {"error": "local only"})
                return self._send(200, helpdesk.answers(m.group(1)))
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
            m = WORKER.match(u.path)
            if m and m.group(3) == "log":
                from .tools import find_job, job_messages
                p = broker.projects.get(m.group(1))
                own = assistants.get(p.name).meta.get("session_id", "") if assistants else ""
                job = find_job(p.paths, m.group(2), exclude_session=own)
                if job is None:
                    return self._send(404, {"error": "no such conversation in this project"})
                return self._send(200, {"worker": job, "messages": job_messages(job)})
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
            if m and m.group(2) == "file" and assistants:
                f = uploads.inside((q.get("path") or [""])[0], assistants.get(m.group(1)).uploads)
                if f is None:
                    return self._send(404, {"error": "no such attachment"})
                data = f.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", mimetypes.guess_type(f.name)[0] or "application/octet-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            self._send(404, {"error": "not found"})

        def _post(self):
            if self.headers.get("X-Ghost") != "1":
                return self._send(403, {"error": "missing X-Ghost header"})
            u = urlparse(self.path)
            if u.path == "/api/uploads":
                q = parse_qs(u.query)
                folder = self._upload_dir((q.get("project") or [""])[0], (q.get("to") or [""])[0])
                if folder is None:
                    return self._send(404, {"ok": False, "message": "找不到要傳給的對象"})
                data = self._raw()
                if not data:
                    return self._send(413, {"ok": False, "message": "檔案是空的或超過 30 MB"})
                path = uploads.save(folder, (q.get("name") or ["file"])[0], data)
                return self._send(200, {"ok": True, **uploads.describe(path)})
            try:
                body = self._body()
            except ValueError:
                return self._send(400, {"error": "bad json"})
            if u.path in ("/api/projects", "/api/projects/probe") and setup is not None:
                # A bot token and who may command an assistant: this Mac only
                # (MyGhost on another Mac comes in over its SSH forward).
                if not self._local():
                    return self._send(403, {"ok": False, "message": "只能在本機新增"})
                code, r = (setup.probe if u.path.endswith("/probe") else setup.create)(body)
                return self._send(code, r)
            if u.path in ("/hook/permission", "/hook/event", "/hook/context", "/api/help") \
                    or u.path.startswith("/assistant-tools/"):
                if not self._local():
                    return self._send(403, {"error": "local only"})
            if u.path == "/hook/context":
                return self._send(200, {"context": helpdesk.context_for(str(body.get("cwd") or "")) if helpdesk else ""})
            if u.path == "/api/help":
                if helpdesk is None:
                    return self._send(404, {"ok": False, "message": "沒有啟用求助"})
                r = helpdesk.ask(body)
                return self._send(200 if r.get("ok") else 400, r)
            if u.path == "/hook/permission":
                return self._send(200, broker.request_permission(body, alive=self._client_connected))
            if u.path == "/hook/event":
                broker.hook_event(body)
                return self._send(200, {"ok": True})
            m = WORKER.match(u.path)
            if m and m.group(3) == "remove":
                from .tools import find_job, job_remove
                p = broker.projects.get(m.group(1))
                own = assistants.get(p.name).meta.get("session_id", "") if assistants else ""
                job = find_job(p.paths, m.group(2), exclude_session=own)
                if job is None:
                    return self._send(404, {"ok": False, "message": "找不到這個專案的這個對話"})
                err = job_remove(job)
                log(f"worker {job['id']} ({job.get('name', '')}) removed" if not err
                    else f"worker {job['id']} remove refused: {err[:200]}")
                broker.bump()
                return self._send(200 if not err else 409, {"ok": not err, "message": err or "已刪除"})
            if m and m.group(3) == "send":
                from .tools import find_job, job_send
                p = broker.projects.get(m.group(1))
                own = assistants.get(p.name).meta.get("session_id", "") if assistants else ""
                job = find_job(p.paths, m.group(2), exclude_session=own)
                if job is None:
                    return self._send(404, {"ok": False, "message": "找不到這個專案的這個對話"})
                files = self._files(body, Path(job["cwd"]) / uploads.WORKER_DIR if job.get("cwd") else None)
                if files is None:
                    return self._send(400, {"ok": False, "message": "附件不在這個對話的上傳資料夾裡"})
                text = str(body.get("text") or "").strip()
                if not text and not files:
                    return self._send(400, {"ok": False, "message": "沒有內容"})
                err = job_send(job, uploads.worker_text(text[:20000], files))
                return self._send(200 if not err else 409, {"ok": not err, "message": err or "已送出"})
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
                    files = self._files(body, a.uploads)
                    if files is None:
                        return self._send(400, {"ok": False, "message": "附件不在助手的上傳資料夾裡"})
                    if not text and not files:
                        return self._send(400, {"error": "empty"})
                    src = body.get("source") if body.get("source") in ("myghost", "web") else "myghost"
                    a.send(text[:20000], src, files=files)
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
          remote_token: str = "", dispatcher=None, helpdesk=None, setup=None) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((host, port), make_handler(broker, assistants, tools, remote_token, dispatcher,
                                                           helpdesk, setup))
    httpd.daemon_threads = True
    log(f"http: listening on {host}:{port}")
    return httpd
