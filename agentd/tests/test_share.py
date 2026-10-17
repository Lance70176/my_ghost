"""share_report: the same report keeps its link."""

import stat

from ghost_agentd import tools
from test_assistant import manager  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


def fake_share(tmp_path):
    """New token each time; -u keeps the token, unless it's in `expired`."""
    s = tmp_path / "share"
    s.write_text("#!/bin/bash\n"
                 f"echo \"$@\" >> {tmp_path}/calls\n"
                 "if [ \"$1\" = -u ]; then\n"
                 f"  grep -qx \"$2\" {tmp_path}/expired 2>/dev/null && exit 2\n"
                 "  echo \"$2\"; exit 0\n"
                 "fi\n"
                 "echo \"https://files.example/$(openssl rand -hex 5)/$(basename \"$1\")\"\n")
    s.chmod(s.stat().st_mode | stat.S_IEXEC)
    return s


def test_same_report_same_link(broker, manager, tmp_path, monkeypatch):
    monkeypatch.setattr(tools, "SHARE", str(fake_share(tmp_path)))
    t = tools.Tools(broker, manager, lambda name: None)
    p = broker.projects.get("fq")
    report = tmp_path / "2026-10-17-estimate.html"
    report.write_text("v1")
    url = lambda out: out.splitlines()[0].removeprefix("連結：").split("（")[0]
    first = url(t.t_share_report(p, {"path": str(report)}))
    report.write_text("v2")
    out = t.t_share_report(p, {"path": str(report)})
    assert url(out) == first and "沿用" in out
    assert (p.dir / "reports" / report.name).read_text() == "v2"  # the copy behind it is new

    other = tmp_path / "2026-10-17-other.html"
    other.write_text("x")
    assert url(t.t_share_report(p, {"path": str(other)})) != first  # another report, its own link
    assert url(t.t_share_report(p, {"path": str(report), "new_link": True})) != first  # asked for one

    # The old link expired: a new one, remembered from then on.
    latest = url(t.t_share_report(p, {"path": str(report)}))
    (tmp_path / "expired").write_text(latest + "\n")
    renewed = url(t.t_share_report(p, {"path": str(report)}))
    assert renewed != latest
    assert url(t.t_share_report(p, {"path": str(report)})) == renewed
