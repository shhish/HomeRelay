#!/usr/bin/env python3
"""Smoke-test a running HomeRelay.

Checks health, auth, the read routes and the event stream with a temporary
token that is removed afterwards. With --write NAME it also toggles that
accessory twice (so it ends where it started) and checks the change event.

  scripts/smoke.py
  scripts/smoke.py --write "Desk Lamp"
  scripts/smoke.py --base http://my-mac.local:18796
"""

import argparse
import importlib.machinery
import importlib.util
import json
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
_loader = importlib.machinery.SourceFileLoader("homerelay_token", str(HERE / "homerelay-token"))
_spec = importlib.util.spec_from_loader("homerelay_token", _loader)
tokens = importlib.util.module_from_spec(_spec)
_loader.exec_module(tokens)

failures: list[str] = []


def check(label: str, ok: bool, detail: str = "") -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {label}{f' - {detail}' if detail else ''}")
    if not ok:
        failures.append(label)


def call(
    base: str,
    method: str,
    path: str,
    token: str | None = None,
    body: dict | None = None,
    timeout: float = 30,
):
    req = urllib.request.Request(base + path, method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=data, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def listen(
    base: str, token: str, accessory_id: str, found: threading.Event, stop: threading.Event
) -> None:
    query = urllib.parse.urlencode({"accessory": accessory_id})
    req = urllib.request.Request(
        f"{base}/api/v1/events?{query}", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            for raw in resp:
                if stop.is_set():
                    return
                line = raw.decode().strip()
                if line.startswith("data: ") and accessory_id in line:
                    found.set()
                    return
    except Exception:
        pass


def first_replayed_id(base: str, token: str, since: int) -> int | None:
    """Opens the stream at `since` and returns the first event id replayed."""
    req = urllib.request.Request(
        f"{base}/api/v1/events?since={since}", headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            for raw in resp:
                line = raw.decode().strip()
                if line.startswith("id: "):
                    return int(line[4:])
    except Exception:
        return None
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="http://127.0.0.1:18796")
    parser.add_argument(
        "--write", metavar="ACCESSORY", help="toggle this accessory twice and expect an event"
    )
    args = parser.parse_args()
    base = args.base.rstrip("/")

    status, health = call(base, "GET", "/api/v1/health")
    check("health responds", status == 200, json.dumps(health))
    if health.get("homekit") != "ready":
        print(f"HomeKit is '{health.get('homekit')}', so only health was checked.")
        return 1

    name = f"smoke-{int(time.time())}"
    token = tokens.add(name, read_only=not args.write)
    try:
        check("no token is rejected", call(base, "GET", "/api/v1/homes")[0] == 401)
        check("bad token is rejected", call(base, "GET", "/api/v1/homes", "hr_wrong")[0] == 401)

        status, homes = call(base, "GET", "/api/v1/homes", token)
        check(
            "homes",
            status == 200 and len(homes) > 0,
            ", ".join(f"{h['name']} ({h['accessories']} accessories)" for h in homes),
        )

        start = time.monotonic()
        status, accessories = call(base, "GET", "/api/v1/accessories?refresh=1", token, timeout=60)
        elapsed = time.monotonic() - start
        reachable = [a for a in accessories if a["reachable"]] if status == 200 else []
        check(
            "accessories with fresh values",
            status == 200 and len(accessories) > 0,
            f"{len(accessories)} total, {len(reachable)} reachable, {elapsed:.1f}s",
        )

        status, rooms = call(base, "GET", "/api/v1/rooms", token)
        check("rooms", status == 200, f"{len(rooms)} rooms")
        status, scenes = call(base, "GET", "/api/v1/scenes", token)
        check("scenes", status == 200, f"{len(scenes)} scenes")

        if accessories:
            first = accessories[0]
            status, one = call(
                base, "GET", "/api/v1/accessories/" + urllib.parse.quote(first["id"]), token
            )
            check("accessory by id", status == 200 and one["id"] == first["id"], first["name"])

        if health.get("eventLog") == "ok":
            status, stats = call(base, "GET", "/api/v1/events/stats?hours=24", token)
            latest = stats.get("latestSeq", 0) if status == 200 else 0
            check(
                "event log stats",
                status == 200,
                f"seq {latest}, {stats.get('rows')} rows, {stats.get('bytes', 0) // 1024} KB, "
                f"24h by origin {stats.get('byOrigin')}"
                if status == 200
                else json.dumps(stats),
            )
            if latest > 0:
                # Samples aren't streamed, so the newest few may all be hidden; replay from the start.
                replayed = first_replayed_id(base, token, 0)
                check(
                    "stream replays from since",
                    replayed is not None and 0 < replayed <= latest,
                    f"since=0 -> first id {replayed}",
                )

        if not args.write:
            check(
                "read token cannot write",
                call(base, "POST", "/api/v1/scenes/x/run", token)[0] == 403,
            )
            return 0 if not failures else 1

        ref = urllib.parse.quote(args.write)
        status, target = call(base, "GET", f"/api/v1/accessories/{ref}", token)
        check(
            f"find '{args.write}'",
            status == 200,
            json.dumps(target)[:200] if status != 200 else target["id"],
        )
        if status != 200:
            return 1
        before = target["state"]

        found, stop = threading.Event(), threading.Event()
        listener = threading.Thread(
            target=listen, args=(base, token, target["id"], found, stop), daemon=True
        )
        listener.start()
        time.sleep(1)
        status, after = call(base, "POST", f"/api/v1/accessories/{ref}/toggle", token)
        check(
            "toggle", status == 200, f"{before} -> {after.get('state') if status == 200 else after}"
        )
        check("change event delivered", found.wait(10))
        stop.set()
        time.sleep(1)
        status, restored = call(base, "POST", f"/api/v1/accessories/{ref}/toggle", token)
        check(
            "toggle back",
            status == 200,
            f"now {restored.get('state') if status == 200 else restored}",
        )
    finally:
        tokens.revoke(name)

    print(
        "\nAll checks passed."
        if not failures
        else f"\n{len(failures)} check(s) failed: {', '.join(failures)}"
    )
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
