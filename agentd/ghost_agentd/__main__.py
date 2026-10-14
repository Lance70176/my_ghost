"""ghost-agentd: the always-on, no-LLM service behind the project assistants.

    python -m ghost_agentd            run (launchd does this)
    python -m ghost_agentd check      validate config and print the projects
    python -m ghost_agentd account-login <project>
                                      log the project's work TG account in
                                      (you type the code Telegram sends)
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
        if p.tg_account:
            from .account import session_file
            state = "logged in" if session_file(p).exists() else "NOT logged in (run account-login)"
            print(f"  work account {p.tg_account.get('phone', '?')[:4]}…: {state}")
    return 0


def main() -> int:
    if sys.argv[1:2] == ["check"]:
        return check()
    if sys.argv[1:2] == ["account-login"] and len(sys.argv) > 2:
        from .account import login
        return login(cfgmod.Projects().get(sys.argv[2]))
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
    accounts = {}
    for p in projects.all():
        if p.tg_account:
            w = AccountWatcher(broker, assistants, p)
            w.transport = TelethonAccount(p, w)
            if w.transport.start():
                accounts[p.name] = w
                broker.listeners.append(w)
    from .watchcmd import WatchCommands
    watch_commands = WatchCommands(accounts)
    for bot in bots:
        bot.watch_commands = watch_commands
    from .sources import Sources
    sources = Sources(projects, assistants)
    sources.reload()
    from .dispatch import Dispatcher
    dispatcher = Dispatcher(broker, assistants)
    broker.listeners.append(dispatcher)
    from .helpdesk import HelpDesk
    helpdesk = HelpDesk(broker, assistants)
    tools = Tools(broker, assistants, bot_for, accounts, sources, dispatcher, helpdesk)
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
    httpd = serve(broker, host, cfg.port, assistants, tools, cfg.remote_token, dispatcher, helpdesk)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
