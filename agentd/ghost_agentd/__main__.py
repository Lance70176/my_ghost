"""ghost-agentd: the always-on, no-LLM service behind the project assistants.

    python -m ghost_agentd            run (launchd does this)
    python -m ghost_agentd check      validate config and print the projects
"""

from __future__ import annotations

import sys
import threading
import time

from . import config as cfgmod
from .broker import Broker, log
from .server import serve
from .telegram import build_bots


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
    return 0


def main() -> int:
    if sys.argv[1:2] == ["check"]:
        return check()
    cfg = cfgmod.load_config()
    projects = cfgmod.Projects()
    broker = Broker(cfg, projects)
    bots = build_bots(cfg, broker)
    if not bots:
        log("telegram: no bot configured — cards only in MyGhost / the phone page")
    for bot in bots:
        broker.listeners.append(bot)
        bot.start()

    def ticker():
        while True:
            time.sleep(5)
            try:
                broker.flush_digests()
            except Exception as e:
                log(f"digest failed: {e!r}")

    threading.Thread(target=ticker, name="ticker", daemon=True).start()
    httpd = serve(broker, cfg.host, cfg.port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
