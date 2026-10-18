"""A work account is set up once (~/.myghost/accounts/<name>) and shared
out: one connection, each message to exactly one project by its routes."""

import asyncio

import yaml

from ghost_agentd import account
from ghost_agentd.account import AccountWatcher
from ghost_agentd.workaccounts import AccountConfig, LaneTransport, Route, WorkAccount, find, load_accounts
from test_account import FakeClient, FakeEvent, FakeMsg, FakeTransport, let_in, msg
from test_assistant import manager, wait_for  # noqa: F401  (fixtures)
from test_broker import broker, home  # noqa: F401  (fixtures)


def add_lts(home, broker):
    lts = home / "projects" / "lts"
    lts.mkdir(parents=True)
    (lts / "project.yaml").write_text("paths: []\nresident: false\n")
    broker.projects.reload()
    return broker.projects.get("lts")


def test_a_projects_own_login_becomes_an_account(home, broker):
    p = broker.projects.get("fq")
    (p.dir / "project.yaml").write_text(
        "paths: []\ntelegram:\n  account: {api_id: 1, api_hash: abc, phone: '+886900'}\n")
    (p.dir / "account.session").write_text("SESSION")
    (p.dir / "watch.yaml").write_text("window: always\nfolders:\n  - folder: FQ\n    trigger: all\n")
    broker.projects.reload()
    accs = load_accounts(broker.projects)
    assert [a.name for a in accs] == ["fq"]
    a = accs[0]
    assert a.phone == "+886900" and a.api_id == "1"
    assert [(r.kind, r.value, r.project) for r in a.routes] == [("folder", "FQ", "fq")]
    assert a.session_file.read_text() == "SESSION" and (p.dir / "account.session").exists()
    assert oct(a.session_file.stat().st_mode)[-3:] == "600"
    # Done once: the same phone isn't made again, and it's found by project too.
    assert len(load_accounts(broker.projects)) == 1
    assert find("fq", broker.projects).name == "fq"
    # No folders in watch.yaml: everything goes to the project.
    q = add_lts(home, broker)
    (q.dir / "project.yaml").write_text("paths: []\ntelegram:\n  account: {api_id: 2, api_hash: d, phone: '+886911'}\n")
    broker.projects.reload()
    lts = next(a for a in load_accounts(broker.projects) if a.name == "lts")
    assert [(r.kind, r.project) for r in lts.routes] == [("all", "lts")]


def shared(broker, manager, routes):
    wa = WorkAccount(AccountConfig("brave", broker.projects.get("fq").dir, "1", "h", "+1", routes))
    for name in dict.fromkeys(r.project for r in routes):
        lane = AccountWatcher(broker, manager, broker.projects.get(name), None)
        (lane.project.dir / "watch.yaml").write_text("window: always\nbatch: 0\n")
        wa.lanes[name] = lane
    return wa


def test_one_account_two_assistants(home, broker, manager):
    add_lts(home, broker)
    wa = shared(broker, manager, [Route("folder", "LTS", "lts"), Route("group", "FQ 研發群", "fq"),
                                  Route("all", "", "fq")])
    fq, lts = wa.lanes["fq"], wa.lanes["lts"]
    m = msg(chat="LTS 群", chat_id=-1, folders=["LTS"], text="閒聊")
    assert wa.route(m) is lts and m.via["kind"] == "folder"
    assert lts.match(m)  # the route's trigger: all
    dm = msg(private=True, chat="Candy", chat_id=5, folders=["LTS"])
    assert wa.route(dm) is lts and lts.match(dm)  # assigned by folder: no grant needed
    g = msg(chat="FQ 研發群", chat_id=-2, text="閒聊")
    assert wa.route(g) is fq and fq.match(g)
    stranger = msg(private=True, chat="Amy", chat_id=6)
    assert wa.route(stranger) is fq and stranger.via == {}
    assert fq.match(stranger) is None  # by fq's own rules: a private chat needs a grant
    let_in(fq, 6)
    assert fq.match(stranger)


def test_a_chat_two_routes_want_goes_to_the_first(home, broker, manager, capsys):
    add_lts(home, broker)
    wa = shared(broker, manager, [Route("folder", "LTS", "lts"), Route("chat", "-9", "fq")])
    m = msg(chat="共用群", chat_id=-9, folders=["LTS"])
    assert wa.route(m) is wa.lanes["lts"]
    assert "matches 2 routes" in capsys.readouterr().out


def test_watch_groups_claim_before_everything_else(home, broker, manager):
    add_lts(home, broker)
    wa = shared(broker, manager, [Route("folder", "LTS", "lts"), Route("all", "", "fq")])
    lts = wa.lanes["lts"]
    (lts.project.dir / "watch.yaml").write_text("window: always\ngroups:\n  - group: 日報群\n    trigger: all\n")
    lts._watch = None
    m = msg(chat="日報群", chat_id=-3, text="今天的日報")
    assert wa.route(m) is lts and lts.match(m)


def test_unrouted_is_only_recorded(home, broker, manager):
    add_lts(home, broker)
    wa = shared(broker, manager, [Route("folder", "LTS", "lts")])
    lane = wa.lanes["lts"]
    lane.transport = FakeTransport()
    t = account.TelethonAccount(wa)
    t.client = FakeClient()
    t._folder_cache, t._folder_at = [], 1e18  # the account has no folders
    asyncio.run(t._handle(FakeEvent(FakeMsg(10)), my_id=1))
    assert not lane.inbox
    rec = (wa.cfg.dir / "unrouted.jsonl").read_text()
    assert "Danny" in rec and "看這個" not in rec  # who and where, not what


def test_routed_message_downloads_into_its_project(home, broker, manager):
    add_lts(home, broker)
    wa = shared(broker, manager, [Route("chat", "42", "lts"), Route("all", "", "fq")])
    t = account.TelethonAccount(wa)
    t.client = FakeClient()
    asyncio.run(t._handle(FakeEvent(FakeMsg(10)), my_id=1))
    lts = wa.lanes["lts"]
    m = next(iter(lts.inbox.values()))
    assert m.files and m.files[0].startswith(str(lts.uploads)) and not wa.lanes["fq"].inbox
    assert lts.queue  # a private chat routed here by name goes on without a grant


def test_own_send_through_any_lane_isnt_the_owner(home, broker, manager):
    add_lts(home, broker)
    wa = shared(broker, manager, [Route("folder", "LTS", "lts"), Route("all", "", "fq")])
    lts = wa.lanes["lts"]
    m = msg(private=True, chat="Candy", chat_id=5, folders=["LTS"])
    wa.route(m)
    assert lts.on_message(m) and lts.queue
    lts._sending(5)
    wa.on_mine(5, m.ts + 10)  # the account's copy of that send
    assert lts.queue
    lts.own_sends.clear()
    wa.on_mine(5, m.ts + 10)  # the owner answering by hand
    assert not lts.queue


def test_lane_transport_reads_into_its_project():
    calls = []

    class Shared:
        def history(self, chat_id, limit, lane):
            calls.append((chat_id, limit, lane))
            return []

        def send(self, *a):
            calls.append(a)

    lt = LaneTransport(Shared(), "lane-lts")
    lt.history(5, 20)
    lt.send(5, "hi", None)
    assert calls == [(5, 20, "lane-lts"), (5, "hi", None)]


def test_routes_parse(tmp_path):
    d = tmp_path / "brave"
    d.mkdir()
    (d / "account.yaml").write_text(yaml.safe_dump({
        "api_id": 1, "api_hash": "h", "phone": "+1",
        "routes": [{"folder": "LTS", "project": "lts", "trigger": "mention", "window": "always"},
                   {"private": True, "project": "fq"}, {"all": True, "project": "fq"},
                   {"project": "fq"}, {"group": "x"}]}))
    a = AccountConfig.load(d)
    assert [(r.kind, r.value, r.project) for r in a.routes] == [
        ("folder", "LTS", "lts"), ("private", "", "fq"), ("all", "", "fq")]
    assert a.routes[0].trigger == "mention" and a.projects == ["lts", "fq"]
