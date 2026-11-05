#!/usr/bin/env python3
"""Cluster + process status from the shared database (via the load balancer).

Shows instance counts per outcome, open incidents, which node/engine executed each step, and
instances whose steps ran on BOTH engines (started on Camunda, finished on CIB seven) - the rolling-upgrade proof.
  python3 status.py
"""
import collections
import json
import os
import urllib.parse
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
KEY = "numberPorting"
ORDER = ["validateRequest", "notifyRejected", "provisionHss", "activateNumber"]  # process order of the steps


def get(path: str, **params):
    url = f"{LB}{path}?{urllib.parse.urlencode(params)}" if params else LB + path
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)


def main() -> None:
    pis = get("/history/process-instance", processDefinitionKey=KEY, maxResults=5000)
    by_id = {p["id"]: p for p in pis}
    states = collections.Counter(p["state"] for p in pis)
    ends = collections.Counter()
    for a in get("/history/activity-instance", processDefinitionKey=KEY, activityType="noneEndEvent", maxResults=5000):
        ends[a.get("activityName") or a["activityId"]] += 1
    incidents = get("/incident/count", processDefinitionKeyIn=KEY)["count"]

    print(f"Instances: {len(pis)}  " + "  ".join(f"{k.lower()}={v}" for k, v in sorted(states.items())))
    print("Outcomes:  " + "  ".join(f"{k}={v}" for k, v in sorted(ends.items())) + f"   open incidents={incidents}")

    runs = collections.defaultdict(dict)  # pi -> {activity: "node / engine"}
    for v in get("/history/variable-instance", variableNameLike="%_executedBy", maxResults=20000):
        if v["processInstanceId"] in by_id:
            runs[v["processInstanceId"]][v["name"].removesuffix("_executedBy")] = v["value"]

    matrix = collections.Counter((act, who) for steps in runs.values() for act, who in steps.items())
    print("\nSteps executed per node / engine:")
    for (act, who), n in sorted(matrix.items()):
        print(f"  {act:<28} {who:<36} {n:>5}")

    mixed = [pi for pi, steps in runs.items()
             if any("Camunda" in w for w in steps.values()) and any("CIB seven" in w for w in steps.values())]
    print(f"\nInstances that ran on BOTH engines (started on Camunda, continued on CIB seven): {len(mixed)}")
    for pi in mixed[:5]:
        p = by_id[pi]
        steps = sorted(runs[pi].items(), key=lambda x: ORDER.index(x[0]) if x[0] in ORDER else len(ORDER))
        path = "  ->  ".join(f"{a}@{w}" for a, w in steps)
        print(f"  {p.get('businessKey')} [{p['state'].lower()}]  {path}")


if __name__ == "__main__":
    main()
