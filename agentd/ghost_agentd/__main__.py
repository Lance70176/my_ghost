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
from .telegram import Telegram


def check() -> int:
    cfg = cfgmod.load_config()
    projects = cfgmod.Projects()
    print(f"home: {cfgmod.HOME}")
    print(f"http: {cfg.host}:{cfg.port}  timeout: {cfg.decision_timeout}s")
    tg = cfg.telegram
    print(f"telegram: token {'set' if tg.token else 'MISSING'}, chat_id {tg.chat_id}, "
          f"allowed users {tg.allowed_user_ids or 'none'}")
    if tg.token and not tg.allowed_user_ids and (tg.chat_id or 0) < 0:
        print("  ! chat_id is a group but allowed_user_ids is empty: buttons will be ignored")
    for p in projects.all():
        print(f"project {p.name}: topic {p.topic_id}, paths {p.paths or '-'}, "
              f"{len(p.policy.allow)} always-allow rules")
    return 0


def main() -> int:
    if sys.argv[1:2] == ["check"]:
        return check()
    cfg = cfgmod.load_config()
    projects = cfgmod.Projects()
    broker = Broker(cfg, projects)
    tg = Telegram(cfg, broker)
    broker.listeners.append(tg)
    tg.start()

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
