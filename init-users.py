#!/usr/bin/env python3
"""Create demo user demo/demo as administrator (group camunda-admin, ALL on every resource type) via engine REST.

Same result as the first-start admin setup page; works for Camunda 7.24 and CIB seven (shared identity tables).
  python3 init-users.py [engine-rest-url]
"""
import json
import os
import sys
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

REST = sys.argv[1] if len(sys.argv) > 1 else f"http://localhost:{setting('LB_PORT', '8088')}/engine-rest"


def post(path: str, body: dict) -> int:
    req = urllib.request.Request(REST + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def main() -> None:
    print("user demo:", post("/user/create", {"profile": {"id": "demo", "firstName": "Demo", "lastName": "User",
                                                          "email": "demo@example.com"},
                                              "credentials": {"password": "demo"}}))
    print("group camunda-admin:", post("/group/create", {"id": "camunda-admin", "name": "Administrators", "type": "SYSTEM"}))
    req = urllib.request.Request(REST + "/group/camunda-admin/members/demo", method="PUT")
    try:
        urllib.request.urlopen(req, timeout=10)
        print("membership: ok")
    except urllib.error.HTTPError as e:
        print("membership:", e.code)
    ok = 0
    for resource_type in range(0, 22):
        ok += post("/authorization/create", {"type": 1, "permissions": ["ALL"], "groupId": "camunda-admin",
                                             "resourceType": resource_type, "resourceId": "*"}) == 200
    print(f"authorizations created: {ok}")


if __name__ == "__main__":
    main()
