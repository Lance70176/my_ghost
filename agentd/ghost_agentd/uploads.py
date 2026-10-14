"""Files people attach to a message — to a project assistant or to one of the
project's conversations.

They are stored where the reader can open them without asking: the
assistant's own folder (it runs with --add-dir on it) or, for a conversation,
`.myghost-uploads` inside its working directory (Claude Code only embeds
pasted image paths that are inside the workspace).
"""
from __future__ import annotations

import base64
import os
import re
import secrets
import time
from pathlib import Path

MAX_BYTES = 30 * 1024 * 1024
# The API takes an image of up to 5 MB base64; bigger ones go by path.
INLINE_IMAGE_BYTES = 3_700_000
IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
               ".gif": "image/gif", ".webp": "image/webp"}
WORKER_DIR = ".myghost-uploads"


def safe_name(name: str) -> str:
    name = os.path.basename(name or "").strip() or "file"
    name = re.sub(r"[^\w.\-() ]+", "_", name)
    return name[-120:].lstrip(".") or "file"


def save(folder: Path, name: str, data: bytes) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = folder / f"{stamp}-{secrets.token_hex(2)}-{safe_name(name)}"
    path.write_bytes(data)
    return path


def kind(path: str | Path) -> str:
    return "image" if Path(path).suffix.lower() in IMAGE_TYPES else "file"


def shown_name(path: Path) -> str:
    """The name it was attached under (without our stamp)."""
    m = re.match(r"^\d{8}-\d{6}-[0-9a-f]{4}-(.+)$", path.name)
    return m.group(1) if m else path.name


def describe(path: Path) -> dict:
    """What MyGhost shows for an attachment."""
    return {"name": shown_name(path), "path": str(path), "kind": kind(path),
            "size": path.stat().st_size if path.exists() else 0}


def inside(path: str, folder: Path) -> Path | None:
    """The file, if it really is one of ours in `folder` (no escaping it)."""
    try:
        p = Path(path).resolve()
        root = folder.resolve()
    except (OSError, RuntimeError):
        return None
    if root in p.parents and p.is_file():
        return p
    return None


def content_blocks(text: str, files: list[Path]) -> list[dict] | str:
    """A user message in stream-json form: the text, a list of the files (so
    they can be opened again later), and small images inline so they are seen
    straight away."""
    if not files:
        return text
    lines = [text] if text else []
    lines.append("附件（已存檔，需要時可用 Read 開啟）：")
    lines += [f"- {shown_name(f)}：{f}" for f in files]
    blocks: list[dict] = [{"type": "text", "text": "\n".join(lines)}]
    for f in files:
        media = IMAGE_TYPES.get(f.suffix.lower())
        if media and f.stat().st_size <= INLINE_IMAGE_BYTES:
            blocks.append({"type": "image", "source": {
                "type": "base64", "media_type": media,
                "data": base64.b64encode(f.read_bytes()).decode()}})
    return blocks


def worker_text(text: str, files: list[Path]) -> str:
    """What gets typed into a conversation: the message, then the paths."""
    return "\n".join([t for t in [text] if t] + [str(f) for f in files])
