#!/usr/bin/env python3
"""Continuous load through the load balancer: starts numberPorting instances and shows which node/engine served each start.

  python3 load.py            # one start every 2 s, until Ctrl+C
  python3 load.py 1 200      # one start per second, 200 instances

Scenario mix: 70 % success, 15 % reject (BPMN error -> business failure path), 15 % technicalFailure (incident after retries).
"""
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def setting(name: str, default: str) -> str:
    """Environment variable > value in .env (written by reset.sh) > default."""
    if name in os.environ:
        return os.environ[name]
    try:
        for line in (Path(__file__).resolve().parent / ".env").read_text().splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name:
                return value.strip()
    except FileNotFoundError:
        pass
    return default

LB = f"http://localhost:{setting('LB_PORT', '8088')}/engine-rest"
NODES = {"node1": f"http://localhost:{setting('NODE1_PORT', '8081')}/engine-rest",
         "node2": f"http://localhost:{setting('NODE2_PORT', '8082')}/engine-rest"}
SCENARIOS = ["success"] * 14 + ["reject"] * 3 + ["technicalFailure"] * 3
OPERATORS = ["Operator A", "Operator B", "Operator C", "Operator D"]  # fictional donor operators
RUN = time.strftime("%H%M%S")
_engines: dict = {}
_engines_at = 0.0


def engine_of(node: str) -> str:
    global _engines_at
    if time.time() - _engines_at > 3:
        _engines_at = time.time()
        for name, url in NODES.items():
            try:
                with urllib.request.urlopen(url + "/version", timeout=1) as r:
                    v = json.load(r).get("version", "?")
                _engines[name] = f"Camunda {v}" if v.startswith("7.") else f"CIB seven {v}"
            except Exception:
                _engines[name] = "down"
    return _engines.get(node, "?")


def start(i: int) -> tuple[int, str, str]:
    scenario = random.choice(SCENARIOS)
    body = {
        "businessKey": f"PORT-{RUN}-{i:04d}",
        "variables": {
            "msisdn": {"value": f"+1 555 01{random.randint(0, 99):02d}", "type": "String"},  # fictional numbers
            "donorOperator": {"value": random.choice(OPERATORS), "type": "String"},
            "scenario": {"value": scenario, "type": "String"},
        },
    }
    req = urllib.request.Request(LB + "/process-definition/key/numberPorting/start", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.headers.get("X-Served-By", "?"), scenario
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("X-Served-By", "?"), scenario
    except Exception as e:  # connection refused etc.
        return 0, type(e).__name__, scenario


def main() -> None:
    interval = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 10**9
    ok = failed = 0
    try:
        for i in range(1, count + 1):
            status, node, scenario = start(i)
            good = 200 <= status < 300
            ok += good
            failed += not good
            colour = "\033[32m" if good else "\033[1;31m"
            print(f"{time.strftime('%H:%M:%S')}  PORT-{RUN}-{i:04d}  {scenario:<16} -> {node:<6} {engine_of(node):<26} "
                  f"{colour}{status or 'ERR'}\033[0m   ok={ok} failed={failed}", flush=True)
            time.sleep(interval)
    except KeyboardInterrupt:
        pass
    print(f"\nstarted: {ok} ok, {failed} failed")


if __name__ == "__main__":
    main()
