"""Rule-based L0–L3 classification of a permission request.

P1 has no LLM in the loop: every request is graded by the rules below plus the
project's own overrides, and the grade decides what happens:

  L0  allow silently (logged, optionally summarized in a digest)
  L1  allow, then tell the user
  L2  ask the user on a decision card
  L3  ask, and require a second confirmation; can never be "always allowed"

A compound shell command (`a && b | c`) gets the highest grade of its parts.
"""

from __future__ import annotations

import fnmatch
import os
import re
import shlex
from dataclasses import dataclass, field

L0, L1, L2, L3 = 0, 1, 2, 3
LEVEL_NAMES = {L0: "L0", L1: "L1", L2: "L2", L3: "L3"}

# Commands that only read. A command whose first word is here is L0 unless a
# flag or redirection below turns it into a write.
READ_ONLY = {
    "ls", "cat", "head", "tail", "wc", "grep", "rg", "ag", "fd", "tree",
    "pwd", "echo", "printf", "which", "whereis", "type", "file", "stat",
    "du", "df", "diff", "cmp", "sort", "uniq", "cut", "tr", "column", "jq",
    "less", "more", "date", "env", "printenv", "whoami", "id", "hostname",
    "uname", "basename", "dirname", "realpath", "readlink", "true", "false",
    "test", "[", "sleep", "ps", "pgrep", "lsof", "otool", "nm", "strings",
    "shasum", "md5", "sha256sum", "xxd", "hexdump", "od", "plutil",
    "defaults read", "sw_vers", "xcodebuild -list", "tmux list-sessions",
}
GIT_READ = {
    "status", "log", "diff", "show", "branch", "remote", "fetch", "ls-files",
    "rev-parse", "blame", "describe", "shortlog", "grep", "worktree list",
    "stash list", "tag", "config --get", "cat-file", "merge-base",
}
# Running the project's own build or tests is routine.
TEST_PREFIXES = (
    "zig build test", "zig build", "zig fmt", "swiftlint", "prettier",
    "npm test", "npm run test", "npm run lint", "npm run build", "yarn test",
    "pnpm test", "pytest", "python -m pytest", "python3 -m pytest", "go test",
    "go build", "go vet", "cargo test", "cargo build", "cargo check",
    "make test", "xcodebuild build", "xcodebuild -project", "phpunit",
    "vendor/bin/phpunit", "php artisan test", "uv run pytest",
)

# Always L3, whatever the project says: production and money.
L3_PATTERNS = [
    r"\bprod(uction)?\b", r"\bmaster-db\b", r"正式",
    r"\bwalle\b.*\b(prod|正式|online|release)\b",
    r"\bkubectl\b.*\b(delete|apply|scale|rollout)\b",
    r"\bterraform\s+(apply|destroy)\b",
    r"\b(DROP|TRUNCATE)\s+(TABLE|DATABASE)\b",
    r"\bgit\s+push\b.*(--force|-f\b|\+)",
    r"\brm\s+-[a-zA-Z]*r[a-zA-Z]*f?\s+(/|~|\$HOME)(\s|$)",
    r"\bsudo\b",
]
# L2 unless the project lowers them.
L2_PATTERNS = [
    r"\bgit\s+push\b", r"\bgit\s+merge\b", r"\bgit\s+reset\s+--hard\b",
    r"\bgit\s+(rebase|cherry-pick|revert|clean)\b", r"\bgit\s+branch\s+-D\b",
    r"\bgit\s+checkout\s+--\s", r"\bgit\s+restore\b",
    r"\brm\b", r"\bmv\b", r"\bchmod\b", r"\bchown\b", r"\bkill(all)?\b",
    r"\b(npm|pnpm|yarn)\s+(install|add|i)\b", r"\b(pip3?|uv)\s+(install|add)\b",
    r"\bbrew\s+(install|uninstall|upgrade)\b", r"\bcomposer\s+(require|install)\b",
    r"\bgo\s+get\b", r"\bcargo\s+add\b",
    r"\b(mysql|psql|mongo|mongosh|redis-cli)\b",
    r"\b(curl|wget)\b.*(-X\s*(POST|PUT|DELETE|PATCH)|--data|-d\s)",
    r"\bssh\b", r"\bscp\b", r"\brsync\b",
    r"\bgh\s+(pr|issue|release)\s+(create|merge|close|delete|edit)\b",
    r"\blaunchctl\b", r"\bdocker\s+(rm|rmi|stop|kill|system\s+prune)\b",
    r">\s*/", r"\bdd\b", r"\bshutdown\b", r"\breboot\b",
]

SHELL_SPLIT = re.compile(r"\s*(?:&&|\|\||;|\||\n)\s*")
SENSITIVE_PATH = re.compile(
    r"(^|/)(\.env(\..*)?|\.ssh/.*|\.aws/.*|id_rsa.*|.*\.pem|.*\.key|"
    r"\.claude/settings(\.local)?\.json|\.myghost/.*|credentials.*)$"
)


@dataclass
class Grade:
    level: int
    reason: str
    # Pattern an "always allow" button would add, or None when it can't.
    always_pattern: str | None = None
    matched_rule: str | None = None


@dataclass
class ProjectPolicy:
    """Per-project overrides from project.yaml (`policy:`) and the rules the
    user added with "此專案一律允許"."""

    root_paths: list[str] = field(default_factory=list)
    allow: list[str] = field(default_factory=list)  # L2 -> L1 glob patterns
    deny: list[str] = field(default_factory=list)  # always ask (at least L2)
    l0: list[str] = field(default_factory=list)  # extra silent-allow globs
    l1: list[str] = field(default_factory=list)  # extra allow-then-tell globs
    l3: list[str] = field(default_factory=list)  # extra double-confirm globs/regex


def _first_words(cmd: str, n: int) -> str:
    try:
        words = shlex.split(cmd, posix=True)
    except ValueError:
        words = cmd.split()
    # Skip leading VAR=value assignments.
    while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
        words = words[1:]
    return " ".join(words[:n])


def _glob_any(cmd: str, patterns: list[str]) -> str | None:
    for p in patterns:
        if fnmatch.fnmatchcase(cmd, p) or fnmatch.fnmatchcase(cmd, p + " *"):
            return p
    return None


def _regex_any(text: str, patterns: list[str]) -> str | None:
    for p in patterns:
        try:
            if re.search(p, text, re.IGNORECASE):
                return p
        except re.error:
            if p in text:
                return p
    return None


def _grade_simple(cmd: str, pol: ProjectPolicy) -> Grade:
    cmd = cmd.strip()
    if not cmd:
        return Grade(L0, "空指令")
    hit = _regex_any(cmd, L3_PATTERNS) or _regex_any(cmd, pol.l3)
    if hit:
        return Grade(L3, "正式環境／高風險操作", matched_rule=hit)
    hit = _glob_any(cmd, pol.deny)
    if hit:
        return Grade(L2, "專案黑名單：一律問你", matched_rule=hit)
    hit = _glob_any(cmd, pol.l0)
    if hit:
        return Grade(L0, "專案白名單", matched_rule=hit)
    hit = _glob_any(cmd, pol.l1)
    if hit:
        return Grade(L1, "專案設定：做完再通知", matched_rule=hit)
    hit = _glob_any(cmd, pol.allow)
    if hit:
        return Grade(L1, "此專案一律允許", matched_rule=hit)

    hit = _regex_any(cmd, L2_PATTERNS)
    if hit:
        return Grade(L2, _describe_l2(cmd), always_pattern=suggest_pattern(cmd), matched_rule=hit)

    head1, head2, head3 = (_first_words(cmd, n) for n in (1, 2, 3))
    if head1 == "git":
        sub = head3[4:]
        if any(sub == g or sub.startswith(g + " ") or head2[4:] == g for g in GIT_READ):
            return Grade(L0, "git 唯讀")
        if head2 in ("git add", "git commit", "git stash", "git switch", "git checkout", "git worktree"):
            return Grade(L1, "git 本機變更", always_pattern=suggest_pattern(cmd))
    if head1 == "find":
        if re.search(r"-(delete|exec|execdir|ok)\b", cmd):
            return Grade(L2, "find 會刪檔或執行指令", always_pattern=suggest_pattern(cmd))
        return Grade(L0, "唯讀")
    if head1 == "sed" and not re.search(r"\s-i\b|\s-i\S|--in-place", cmd):
        return Grade(L0, "唯讀")
    if head1 in READ_ONLY or head2 in READ_ONLY:
        if re.search(r"(^|[^>&])>{1,2}\s*[^&\s]", cmd):
            return Grade(L1, "輸出寫入檔案", always_pattern=suggest_pattern(cmd))
        return Grade(L0, "唯讀")
    if any(cmd.startswith(p) for p in TEST_PREFIXES):
        return Grade(L0, "建置／測試")
    return Grade(L2, "未分類的指令", always_pattern=suggest_pattern(cmd))


def _describe_l2(cmd: str) -> str:
    if re.search(r"\bgit\s+push\b", cmd):
        if re.search(r"\b(main|master)\b", cmd):
            return "推送到 main"
        return "推送到遠端分支（不是 main）"
    if re.search(r"\bgit\s+merge\b", cmd):
        return "合併分支"
    if re.search(r"\brm\b", cmd):
        return "會刪除檔案"
    if re.search(r"\b(install|add|require|get)\b", cmd):
        return "新增或變更依賴套件"
    if re.search(r"\b(mysql|psql|mongo|redis-cli)\b", cmd):
        return "連線資料庫"
    if re.search(r"\b(ssh|scp|rsync)\b", cmd):
        return "連到其他主機"
    return "可能改變系統或遠端狀態"


def suggest_pattern(cmd: str) -> str | None:
    """The narrowest useful glob for an "always allow" rule.

    `git push origin feature/okx-link` -> `git push origin feature/*`;
    otherwise the command itself, so a click never allows more than it showed.
    """
    try:
        words = shlex.split(cmd.strip())
    except ValueError:
        return None
    if not words or any(c in cmd for c in "`$<>"):
        return None
    last = words[-1]
    if "/" in last and not last.startswith(("/", "~", ".")):
        words[-1] = last.rsplit("/", 1)[0] + "/*"
    return " ".join(shlex.quote(w) if w != words[-1] or not w.endswith("/*") else w for w in words)


def grade_bash(command: str, pol: ProjectPolicy) -> Grade:
    parts = [p for p in SHELL_SPLIT.split(command) if p.strip()]
    if not parts:
        return Grade(L0, "空指令")
    grades = [_grade_simple(p, pol) for p in parts]
    worst = max(grades, key=lambda g: g.level)
    if re.search(r"\$\(|`", command) and worst.level < L2:
        worst = Grade(L2, "含指令替換，無法靜態判斷")
    if len(parts) > 1:
        # A compound command can only be always-allowed as a whole.
        worst = Grade(worst.level, worst.reason,
                      always_pattern=None if worst.level >= L2 else worst.always_pattern,
                      matched_rule=worst.matched_rule)
        if worst.level == L2:
            worst.always_pattern = suggest_pattern(command) if not re.search(r"[`$<>]", command) else None
    return worst


def _inside(path: str, roots: list[str]) -> bool:
    if not path:
        return False
    p = os.path.realpath(os.path.expanduser(path))
    for r in roots:
        r = os.path.realpath(os.path.expanduser(r))
        if p == r or p.startswith(r.rstrip("/") + "/"):
            return True
    return False


def grade(tool_name: str, tool_input: dict, cwd: str, pol: ProjectPolicy) -> Grade:
    roots = pol.root_paths or ([cwd] if cwd else [])
    if tool_name == "Bash":
        return grade_bash(str(tool_input.get("command", "")), pol)
    if tool_name in ("Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "TodoWrite",
                     "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "ToolSearch"):
        path = tool_input.get("file_path") or tool_input.get("path") or ""
        if path and SENSITIVE_PATH.search(str(path)):
            return Grade(L2, "讀取敏感檔案")
        return Grade(L0, "唯讀")
    if tool_name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")
        if SENSITIVE_PATH.search(path):
            return Grade(L2, "修改敏感檔案（金鑰／設定）")
        hit = _glob_any(f"{tool_name} {path}", pol.allow)
        if _inside(path, roots) or hit:
            return Grade(L0, "修改專案內的檔案")
        return Grade(L2, "修改專案以外的檔案", always_pattern=f"{tool_name} {os.path.dirname(path)}/*")
    if tool_name.startswith("mcp__"):
        hit = _glob_any(tool_name, pol.allow) or _glob_any(tool_name, pol.l0)
        if hit:
            return Grade(L1 if hit in pol.allow else L0, "專案設定", matched_rule=hit)
        short = tool_name.rsplit("__", 1)[-1].lower()
        if re.match(r"^(get|list|search|read|query|find|fetch|filter|describe)", short) or \
                re.search(r"_(get|list|search|read|query)_", short):
            return Grade(L0, "外部服務唯讀")
        if re.search(r"(delete|trash|remove|send|merge|deploy)", short):
            return Grade(L2, "外部服務寫入（刪除／送出）", always_pattern=tool_name)
        return Grade(L2, "外部服務寫入", always_pattern=tool_name)
    hit = _glob_any(tool_name, pol.allow)
    if hit:
        return Grade(L1, "此專案一律允許", matched_rule=hit)
    return Grade(L2, f"工具 {tool_name}", always_pattern=tool_name)


def describe_request(tool_name: str, tool_input: dict) -> str:
    """One line a phone can show: the command, the file, or the tool + args."""
    if tool_name == "Bash":
        return str(tool_input.get("command", ""))
    for k in ("file_path", "notebook_path", "path", "url", "query"):
        if tool_input.get(k):
            return f"{tool_name}({tool_input[k]})"
    brief = ", ".join(f"{k}={str(v)[:40]}" for k, v in list(tool_input.items())[:3])
    return f"{tool_name}({brief})"
