"""Attachments: saved where the reader can open them, never outside."""

import json
import threading
import urllib.error
import urllib.request

from ghost_agentd import server, uploads
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)

PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
                    "0000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082")


def test_names_and_blocks(tmp_path):
    f = uploads.save(tmp_path, "../../畫面 1.png", PNG)
    assert f.parent == tmp_path and f.name.endswith("畫面 1.png")
    assert uploads.describe(f)["name"] == "畫面 1.png"
    assert uploads.describe(f)["kind"] == "image"
    doc = uploads.save(tmp_path, "notes.txt", b"hi")
    A = uploads.Attached
    blocks = uploads.content_blocks("看 [Image #1] 和這份", [A(f, "[Image #1]"), A(doc)])
    assert blocks[0]["type"] == "text" and str(doc) in blocks[0]["text"]
    assert "[Image #1] 畫面 1.png" in blocks[0]["text"]
    # Only the image goes inline, led by its mark.
    assert [b["type"] for b in blocks] == ["text", "text", "image"] and blocks[1]["text"] == "[Image #1]"
    assert uploads.content_blocks("純文字", []) == "純文字"
    assert uploads.worker_text("看", [A(doc)]) == f"看\n{doc}"
    # A mark becomes the path where it stands.
    assert uploads.worker_text("先看[Image #1]再說", [A(f, "[Image #1]")]) == f"先看 {f} 再說"
    assert uploads.label("[Image #2]") == "[Image #2]" and uploads.label("$(rm)") == ""


def test_inside_refuses_escapes(tmp_path):
    (tmp_path / "up").mkdir()
    ok = uploads.save(tmp_path / "up", "a.txt", b"x")
    (tmp_path / "secret").write_text("no")
    assert uploads.inside(str(ok), tmp_path / "up") == ok.resolve()
    assert uploads.inside(str(tmp_path / "up" / ".." / "secret"), tmp_path / "up") is None
    assert uploads.inside("/etc/hosts", tmp_path / "up") is None


def _serve(broker, manager):
    httpd = server.serve(broker, "127.0.0.1", 0, assistants=manager)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}"


def _post(url, data, json_body=True):
    req = urllib.request.Request(url, data=json.dumps(data).encode() if json_body else data,
                                 headers={"X-Ghost": "1"}, method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def test_upload_then_send_to_assistant(broker, manager):
    httpd, base = _serve(broker, manager)
    try:
        code, body = _post(f"{base}/api/uploads?project=fq&to=assistant&name=shot.png", PNG, json_body=False)
        assert code == 200
        info = json.loads(body)
        assert info["kind"] == "image" and info["name"] == "shot.png"
        code, _ = _post(f"{base}/api/assistants/fq/messages",
                        {"text": "看圖 [Image #1]", "files": [{"path": info["path"], "label": "[Image #1]"}]})
        assert code == 200
        a = manager.get("fq")
        wait_for(lambda: any(i.role == "assistant" and "[圖1]" in i.text for i in a.items))
        user = next(i for i in a.items if i.role == "user")
        assert user.files[0]["name"] == "shot.png" and user.files[0]["label"] == "[Image #1]"
        # The preview endpoint serves it back; anything else is refused.
        with urllib.request.urlopen(f"{base}/api/assistants/fq/file?path={info['path']}") as r:
            assert r.read() == PNG
        code, _ = _post(f"{base}/api/assistants/fq/messages", {"text": "x", "files": ["/etc/hosts"]})
        assert code == 400
        try:
            urllib.request.urlopen(f"{base}/api/assistants/fq/file?path=/etc/hosts")
            raise AssertionError("served a file outside uploads")
        except urllib.error.HTTPError as e:
            assert e.code == 404
        # Only attachments, no text, is a message too.
        code, _ = _post(f"{base}/api/assistants/fq/messages", {"files": [info["path"]]})
        assert code == 200
    finally:
        httpd.shutdown()


def test_upload_to_unknown_conversation_is_refused(broker, manager):
    httpd, base = _serve(broker, manager)
    try:
        code, _ = _post(f"{base}/api/uploads?project=fq&to=deadbeef&name=a.txt", b"x", json_body=False)
        assert code == 404
    finally:
        httpd.shutdown()
