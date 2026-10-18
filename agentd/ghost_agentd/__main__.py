"""ghost-agentd: the always-on, no-LLM service behind the project assistants.

    python -m ghost_agentd            run (launchd does this)
    python -m ghost_agentd check      validate config and print the projects
    python -m ghost_agentd account-login <account>
                                      log a work TG account in (its name under
                                      ~/.myghost/accounts, or a project it serves;
                                      you type the code Telegram sends)
"""

from __future__ import annotations

import os
import sys
import threading
import time

from . import config as cfgmod
from .broker import Broker, log
from .server import serve
from .assistant import AssistantManager
from .telegram import build_bots
from .tools import Tools


def check() -> int:
    cfg = cfgmod.load_config()
    projects = cfgmod.Projects()
    print(f"home: {cfgmod.HOME}")
    print(f"http: {cfg.host}:{cfg.port}  timeout: {cfg.decision_timeout}s")
    tg = cfg.telegram
    print(f"commanders: {tg.commander_user_ids or 'NONE — no one can press buttons'}")
    print(f"fallback bot: {'set' if tg.token else '-'}, chat_id {tg.chat_id}")
    for p in projects.all():
        bot = "own bot" if p.tg_token else ("fallback bot" if tg.token else "NO BOT")
        print(f"project {p.name}{' (resident)' if p.resident else ''}: {bot}, chat_id {p.tg_chat_id}, "
              f"paths {p.paths or '-'}, {len(p.policy.allow)} always-allow rules")
    from .workaccounts import load_accounts
    for a in load_accounts(projects):
        state = "logged in" if a.session_file.exists() else "NOT logged in (run account-login)"
        print(f"work account {a.name} ({a.phone[:4]}…): {state}")
        for r in a.routes:
            print(f"  {r.describe()}")
    return 0


def main() -> int:
    if sys.argv[1:2] == ["check"]:
        return check()
    if sys.argv[1:2] == ["account-login"] and len(sys.argv) > 2:
        from .account import login
        from .workaccounts import find
        acc = find(sys.argv[2], cfgmod.Projects())
        if acc is None:
            print(f"沒有叫 {sys.argv[2]} 的帳號（~/.myghost/accounts/<名稱>/account.yaml），也沒有帳號分配給這個專案")
            return 1
        return login(acc)
    cfg = cfgmod.load_config()
    projects = cfgmod.Projects()
    broker = Broker(cfg, projects)
    assistants = AssistantManager(broker, cfg.port)
    broker.listeners.append(assistants)
    bots = build_bots(cfg, broker)
    if not bots:
        log("telegram: no bot configured — cards only in MyGhost / the phone page")
    for bot in bots:
        bot.assistants = assistants
        broker.listeners.append(bot)
        assistants.listeners.append(bot)
        bot.start()

    def bot_for(project: str):
        return next((b for b in bots if b.chat_for(project) is not None), None)

    from .account import AccountWatcher, TelethonAccount
    from .workaccounts import LaneTransport, WorkAccount, load_accounts
    accounts = {}  # project name -> its lane (AccountWatcher) on a shared work account
    for cfg_acc in load_accounts(projects):
        wa = WorkAccount(cfg_acc)
        wa.transport = TelethonAccount(wa)
        for name in cfg_acc.projects:
            if name in accounts:
                log(f"account {wa.name}: project {name} already has a work account; its routes here are ignored")
                continue
            if projects.get(name).name != name:
                log(f"account {wa.name}: routes to unknown project {name}")
                continue
            lane = AccountWatcher(broker, assistants, projects.get(name))
            lane.transport = LaneTransport(wa.transport, lane)
            wa.lanes[name] = lane
        if wa.lanes and wa.transport.start():
            for name, lane in wa.lanes.items():
                accounts[name] = lane
                broker.listeners.append(lane)
    from .watchcmd import WatchCommands
    watch_commands = WatchCommands(accounts)
    for bot in bots:
        bot.watch_commands = watch_commands
    from .sources import Sources
    sources = Sources(projects, assistants)
    sources.reload()
    from .schedule import Schedules
    schedules = Schedules(projects, assistants)
    from .dispatch import Dispatcher
    dispatcher = Dispatcher(broker, assistants)
    broker.listeners.append(dispatcher)
    from .helpdesk import HelpDesk
    helpdesk = HelpDesk(broker, assistants, dispatcher)
    from .dbquery import DBQuery
    dbquery = DBQuery(broker, assistants)
    broker.listeners.append(dbquery)
    tools = Tools(broker, assistants, bot_for, accounts, sources, dispatcher, helpdesk, dbquery)

    def bring_up(name: str) -> None:
        """A project was added from MyGhost: serve it without a restart."""
        for nb in build_bots(cfg, broker):
            bot = next((b for b in bots if b.token == nb.token), None)
            if bot is None:
                nb.assistants = assistants
                nb.watch_commands = watch_commands
                broker.listeners.append(nb)
                assistants.listeners.append(nb)
                bots.append(nb)
                nb.start()
                bot = nb
            for project, chat in nb.routes.items():
                if project not in bot.routes or (bot.routes[project] is None and chat is not None):
                    bot.routes[project] = chat
                    if chat is not None:
                        broker.tg_projects.add(project)
        setup.polled = {b.token for b in bots}
        p = projects.get(name)
        if p.resident and p.paths and os.environ.get("GHOST_NO_ASSISTANTS") != "1":
            assistants.get(name).start()

    from .newproject import ProjectSetup
    setup = ProjectSetup(broker, bring_up)
    setup.polled = {b.token for b in bots}
    if os.environ.get("GHOST_NO_ASSISTANTS") != "1":
        threading.Timer(2, assistants.start_residents).start()

    def ticker():
        while True:
            time.sleep(5)
            try:
                broker.flush_digests()
            except Exception as e:
                log(f"digest failed: {e!r}")
            assistants.tick()
            try:
                sources.tick()
            except Exception as e:
                log(f"sources tick failed: {e!r}")
            try:
                schedules.tick()
            except Exception as e:
                log(f"schedule tick failed: {e!r}")
            for w in list(accounts.values()):
                try:
                    w.tick()
                except Exception as e:
                    log(f"account tick failed: {e!r}")
            try:
                from .tools import close_idle_attachments
                close_idle_attachments()
            except Exception as e:
                log(f"attach cleanup failed: {e!r}")

    threading.Thread(target=ticker, name="ticker", daemon=True).start()
    # With a remote token set, other Macs' MyGhost can reach us (over
    # Tailscale); without one we stay on loopback.
    host = "0.0.0.0" if cfg.remote_token else cfg.host
    httpd = serve(broker, host, cfg.port, assistants, tools, cfg.remote_token, dispatcher, helpdesk, setup)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
