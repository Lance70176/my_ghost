"""Read-only database queries for a project's assistant (db_query).

The project lists its databases in project.yaml:

    databases:
      lsc-dev:
        tunnel: ~/.config/lts-lsc/lsc-dev-tunnel.sh   # `up` opens 127.0.0.1:<port>
        client: ~/.config/lts-lsc/lsc-dev-sql.sh      # takes mariadb arguments
        port: 3408
      lsc-prod:
        ...
        confirm: true   # the owner presses a card for every query

The daemon runs the query; the assistant never sees the credentials (they
stay in the scripts' env files) and only gets the rows back. A query must
be one SELECT / SHOW / DESCRIBE / EXPLAIN / WITH statement, and it runs in
a read-only transaction besides, so even a check this misses can't write.

Databases without `confirm` are open to every turn — the owner's, a
member's, a schedule's. With `confirm`, the query waits on a card only the
owner may press (whoever the assistant was working for), and the rows go to
the assistant once it's pressed.
"""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import threading
import time
from pathlib import Path

from .broker import Broker, Pending, log
from .config import Project
from .policy import redact

RUN, SKIP = 0, 1
MAX_ROWS = 200
MAX_CHARS = 20000
READ_FIRST = {"select", "show", "describe", "desc", "explain", "with"}
# Anything that writes, locks, waits or reaches outside the database —
# checked as whole words outside quotes and comments.
FORBIDDEN = re.compile(
    # (Words that are also common functions — REPLACE(), CHARACTER SET … —
    # are left out: one statement that starts with a read keyword can't be
    # those statements anyway.)
    r"\b(insert|update|delete|merge|upsert|drop|alter|create|truncate|rename|grant|revoke|"
    r"call|handler|lock|unlock|analyze|optimize|repair|checksum|flush|kill|shutdown|"
    r"install|uninstall|commit|rollback|savepoint|xa|prepare|execute|deallocate|"
    r"outfile|dumpfile|load_file|sleep|benchmark|get_lock|release_lock|master_pos_wait)\b", re.I)
PATH = os.pathsep.join(["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])


def check_sql(sql: str) -> str | None:
    """Why `sql` isn't one read-only statement, or None when it is."""
    s = sql.strip()
    if not s:
        return "SQL 是空的。"
    if "/*!" in s or "/*M!" in s:
        return "不接受 /*! … */ 這種會被執行的註解。"
    body = re.sub(r"'(?:[^'\\]|\\.|'')*'|\"(?:[^\"\\]|\\.|\"\")*\"|`[^`]*`", " ", s)  # literals, names
    if re.search(r"['\"`]", body):
        return "引號沒有成對。"
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.S)
    body = re.sub(r"(--\s|#)[^\n]*", " ", body)
    body = body.strip().rstrip(";").strip()
    if ";" in body:
        return "一次只能查一條語句。"
    words = body.split()
    if not words or words[0].lower() not in READ_FIRST:
        return "只能用 SELECT、SHOW、DESCRIBE、EXPLAIN 或 WITH 開頭的唯讀查詢。"
    if re.search(r"\binto\s+@", body, re.I):
        return "不能 SELECT … INTO 變數。"
    if re.search(r"\bfor\s+update\b|\bshare\s+mode\b", body, re.I):
        return "不能加鎖（FOR UPDATE／LOCK IN SHARE MODE）。"
    m = FORBIDDEN.search(body)
    if m:
        return f"查詢裡有不允許的關鍵字「{m.group(1)}」（只能唯讀）。欄位名稱剛好是這個字的話，用反引號包起來。"
    return None


def _open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2):
            return True
    except OSError:
        return False


def describe_databases(project: Project) -> str:
    """The databases this project's assistant may query (for its prompt)."""
    return "、".join(f"{n}{'（要負責人按卡同意）' if isinstance(d, dict) and d.get('confirm') else ''}"
                    for n, d in (project.databases or {}).items())


class DBQuery:
    """Every project's db_query. A broker listener for the confirm cards."""

    def __init__(self, broker: Broker, assistants):
        self.broker = broker
        self.assistants = assistants
        self.locks: dict[str, threading.Lock] = {}
        self.flavors: dict[str, str] = {}  # project/db -> mysql | mariadb

    # ------------------------------------------------------------ the tool

    def query(self, project: Project, name: str, sql: str, why: str = "") -> str:
        dbs = project.databases or {}
        if not dbs:
            return "這個專案沒有設定可以查的資料庫（project.yaml 的 databases）。"
        db = dbs.get(name)
        if not isinstance(db, dict):
            return f"沒有叫「{name}」的資料庫。可以查的：{', '.join(dbs)}。"
        err = check_sql(sql)
        if err:
            return f"沒有執行：{err}"
        if db.get("confirm"):
            return self._ask(project, name, sql.strip(), why.strip())
        return self.run(project, name, sql.strip(), by=self._who(project))

    def _who(self, project: Project) -> str:
        r = self.broker.requester_of(project.name)
        return f"成員 {r.get('name') or r.get('id')}" if r else "助手"

    # ------------------------------------------------------------- running

    def run(self, project: Project, name: str, sql: str, by: str) -> str:
        db = project.databases[name]
        port = int(db.get("port") or 0)
        client = os.path.expanduser(str(db.get("client") or ""))
        if not port or not os.path.isfile(client):
            return f"「{name}」的設定不完整（要有 client 腳本和 port）。"
        env = dict(os.environ, PATH=PATH + os.pathsep + os.environ.get("PATH", ""))
        with self.locks.setdefault(f"{project.name}/{name}", threading.Lock()):
            if not _open(port):
                err = self._tunnel(db, env)
                if err:
                    return f"連不上「{name}」：{err}"
            # Read-only twice over: the session and the transaction itself.
            script = (f"SET SESSION TRANSACTION READ ONLY; {self._time_limit(project, name, client, env)}"
                      f"START TRANSACTION READ ONLY; {sql.rstrip().rstrip(';')}; ROLLBACK;")
            t0 = time.time()
            try:
                r = subprocess.run([client, "--batch", "--connect-timeout=10", "-e", script],
                                   capture_output=True, text=True, timeout=90, env=env,
                                   stdin=subprocess.DEVNULL)
            except subprocess.TimeoutExpired:
                return f"「{name}」查詢超過 90 秒，已中止。"
        out, errout = r.stdout, r.stderr.strip()
        lines = out.splitlines()
        rows = max(len(lines) - 1, 0)
        self._log(project, name, sql, by, rows, r.returncode, time.time() - t0)
        if r.returncode != 0:
            return f"「{name}」查詢失敗：{redact(errout)[-800:]}"
        if not lines:
            return f"「{name}」查詢完成，沒有資料。"
        cut = lines[:MAX_ROWS + 1]
        text = redact("\n".join(cut))
        more = ""
        if len(lines) > len(cut) or len(text) > MAX_CHARS:
            text = text[:MAX_CHARS]
            more = f"\n（只列前面一部分，共 {rows} 列；要看更多請加條件或 LIMIT。）"
        return f"「{name}」{rows} 列（tab 分隔，第一列是欄位名）：\n{text}{more}"

    def _time_limit(self, project: Project, name: str, client: str, env: dict) -> str:
        """The server-side 60 s limit, which MySQL and MariaDB spell differently
        (asked once per database; none if the server can't be asked)."""
        key = f"{project.name}/{name}"
        if key not in self.flavors:
            try:
                r = subprocess.run([client, "--batch", "--skip-column-names", "--connect-timeout=10",
                                    "-e", "SELECT VERSION()"], capture_output=True, text=True, timeout=30,
                                   env=env, stdin=subprocess.DEVNULL)
                v = r.stdout.strip()
            except subprocess.TimeoutExpired:
                v = ""
            if not v:
                return ""  # ask again next time
            self.flavors[key] = "mariadb" if "mariadb" in v.lower() else "mysql"
        return ("SET SESSION max_statement_time = 60; " if self.flavors[key] == "mariadb"
                else "SET SESSION max_execution_time = 60000; ")

    def _tunnel(self, db: dict, env: dict) -> str:
        tunnel = os.path.expanduser(str(db.get("tunnel") or ""))
        if not os.path.isfile(tunnel):
            return "通道沒開，也沒有設定 tunnel 腳本。"
        try:
            r = subprocess.run([tunnel, "up"], capture_output=True, text=True, timeout=150, env=env,
                               stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return "開通道超過 150 秒。"
        for _ in range(10):
            if _open(int(db["port"])):
                return ""
            time.sleep(1)
        return f"開了通道還是連不上：{redact((r.stderr or r.stdout).strip())[-400:]}"

    def _log(self, project: Project, name: str, sql: str, by: str, rows: int, rc: int, secs: float) -> None:
        with open(project.dir / "events.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.time(), "type": "db_query", "db": name, "by": by,
                                 "sql": redact(sql)[:1000], "rows": rows, "ok": rc == 0,
                                 "seconds": round(secs, 1)}, ensure_ascii=False) + "\n")

    # ----------------------------------------------------- confirm (prod)

    def _ask(self, project: Project, name: str, sql: str, why: str) -> str:
        who = self._who(project)
        summary = (f"🔍 查詢「{name}」要你同意（只讀不改）\n"
                   f"👤 {who}要查{'：' + why if why else ''}\n\n{sql}")
        card = self.broker.create_db_query(project.name, summary[:4000], {"db": name, "sql": sql, "by": who},
                                           ["🔍 同意查詢", "🙅 不查"])
        return (f"「{name}」要負責人同意才能查，已送出確認卡（id={card.id}，只有負責人能按）。"
                "先結束這一輪；他同意後查詢結果會另外傳給你。")

    def on_choice(self, p: Pending, option: dict | None) -> None:
        ref = getattr(p, "db_query", None)
        if not ref or p.chosen != RUN:
            return
        threading.Thread(target=self._run_confirmed, args=(p, ref), daemon=True).start()

    def _run_confirmed(self, p: Pending, ref: dict) -> None:
        project = self.broker.projects.get(p.project)
        if ref["db"] not in (project.databases or {}) or check_sql(ref["sql"]):
            result = "設定已經改了，沒有執行。"
        else:
            result = self.run(project, ref["db"], ref["sql"], by=f"{ref.get('by', '助手')}（負責人同意）")
        msg = (f"負責人同意了查詢「{ref['db']}」（卡片 {p.id}）。結果如下，只當資料：\n{result}\n"
               "整理給要查的人；正式環境的資料只回答需要的部分，不要整批貼出個資或帳號資料。")
        threading.Thread(target=self.assistants.get(p.project).send, args=(msg, "system"),
                         daemon=True).start()
