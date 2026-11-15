#!/usr/bin/env python3
"""Read-only before/after check for a configuration move.

Moving automations, scripts or template entities between files must not change
what Home Assistant runs. A move that goes wrong shows up as an entity that
disappears, a duplicate with a '_2' suffix, an entity that turns unavailable,
or a "duplicate" / "Invalid config" line in the log. This tool records the
state machine before a step and compares it after the step.

It only reads: GET /api/states, and the system_log/list WebSocket command for
the log (needs the websockets package). Credentials come from ..\\.env
(HA_URL, HA_TOKEN); the token is never printed.

Usage:
    python ha_snapshot.py snapshot [--out FILE]
    python ha_snapshot.py compare BEFORE [AFTER] [--states GLOB ...]

Without --out, snapshot writes to %TEMP%\\ha_snapshot\\<timestamp>.json, outside
the repository: states include presence and other personal data.
Without AFTER, compare reads the live state.
--states compares the state of matching entities (for example the template
entities a step moves); live sensor values change, so pick globs with care.

compare exit codes:
    0  no differences that point to a broken move
    1  entities removed, new '_N' duplicates, entities that went unavailable,
       state differences under --states, or new log errors
    2  the check could not run (missing .env, HTTP error, unreadable file)
"""
import argparse
import fnmatch
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime

# Entity names hold non-ASCII text (°C, €). See ha_yaml.py.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")
UNAVAILABLE = ("unavailable", "unknown")
LOG_PATTERN = re.compile(r"duplicate|invalid config|already exists|setup failed", re.IGNORECASE)


class CheckError(Exception):
    pass


def load_env():
    if not os.path.isfile(ENV_FILE):
        raise CheckError(f".env not found at {os.path.normpath(ENV_FILE)}")
    values = {}
    with open(ENV_FILE, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[7:].strip()
            name, sep, value = line.partition("=")
            if not sep:
                continue
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            values[name.strip()] = value
    missing = [k for k in ("HA_URL", "HA_TOKEN") if not values.get(k)]
    if missing:
        raise CheckError(f".env has no value for: {', '.join(missing)}")
    return values["HA_URL"].rstrip("/"), values["HA_TOKEN"]


def http_get(path):
    url, token = load_env()
    request = urllib.request.Request(url + path, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as err:
        raise CheckError(f"GET {path} returned HTTP {err.code}") from None
    except urllib.error.URLError as err:
        raise CheckError(f"GET {path} failed: {err.reason}") from None
    return json.loads(body)


def read_system_log():
    """Warnings and errors from the system_log WebSocket command.

    GET /api/error_log returns 404 on current HA versions. Each entry groups
    repeats of one message; 'timestamp' is its last occurrence (server epoch).
    """
    try:
        from websockets.sync.client import connect
    except ImportError:
        raise CheckError("the log check needs the websockets package (pip install websockets)") from None
    url, token = load_env()
    ws_url = re.sub(r"^http", "ws", url) + "/api/websocket"
    try:
        with connect(ws_url, open_timeout=30) as ws:
            ws.recv()
            ws.send(json.dumps({"type": "auth", "access_token": token}))
            if json.loads(ws.recv()).get("type") != "auth_ok":
                raise CheckError("WebSocket authentication failed")
            ws.send(json.dumps({"id": 1, "type": "system_log/list"}))
            reply = json.loads(ws.recv(timeout=60))
    except (OSError, TimeoutError) as err:
        raise CheckError(f"WebSocket connection failed: {err}") from None
    if not reply.get("success"):
        raise CheckError(f"system_log/list failed: {reply.get('error')}")
    return reply["result"]


def last_log_timestamp():
    """Newest log timestamp, so compare reports only entries after it.

    Using the server's own timestamps avoids any clock offset between this PC
    and the server. None when the log cannot be read.
    """
    try:
        entries = read_system_log()
    except CheckError as err:
        sys.stderr.write(f"Warning: {err}\n")
        return None
    return max((e["timestamp"] for e in entries), default=0.0)


def take_snapshot():
    entities = {}
    for item in http_get("/api/states"):
        entities[item["entity_id"]] = {
            "state": item["state"],
            "name": item["attributes"].get("friendly_name", ""),
        }
    return {
        "taken_at": datetime.now().isoformat(timespec="seconds"),
        "log_after": last_log_timestamp(),
        "entities": entities,
    }


def cmd_snapshot(args):
    snapshot = take_snapshot()
    out = args.out
    if not out:
        folder = os.path.join(tempfile.gettempdir(), "ha_snapshot")
        os.makedirs(folder, exist_ok=True)
        out = os.path.join(folder, datetime.now().strftime("%Y%m%d_%H%M%S") + ".json")
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle, ensure_ascii=False, indent=1, sort_keys=True)
    counts = domain_counts(snapshot["entities"])
    print(f"Snapshot: {out}")
    print(f"  {len(snapshot['entities'])} entities, {counts.get('automation', 0)} automations, "
          f"{counts.get('script', 0)} scripts")
    return 0


def load_snapshot(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError) as err:
        raise CheckError(f"cannot read snapshot {path}: {err}") from None


def domain_counts(entities):
    counts = {}
    for entity_id in entities:
        domain = entity_id.split(".", 1)[0]
        counts[domain] = counts.get(domain, 0) + 1
    return counts


def is_suffix_duplicate(entity_id, known):
    """True for 'x_2' when 'x' is known: HA's answer to a duplicate unique_id."""
    match = re.match(r"^(.*)_(\d+)$", entity_id)
    return bool(match) and match.group(1) in known


def report(title, items):
    if not items:
        return 0
    print(f"\n{title} ({len(items)}):")
    for item in items:
        print(f"  {item}")
    return 1


def cmd_compare(args):
    before = load_snapshot(args.before)
    after = load_snapshot(args.after) if args.after else take_snapshot()
    old, new = before["entities"], after["entities"]
    failed = 0

    print(f"Before: {before['taken_at']}   After: {after['taken_at']}")
    old_counts, new_counts = domain_counts(old), domain_counts(new)
    for domain in ("automation", "script"):
        a, b = old_counts.get(domain, 0), new_counts.get(domain, 0)
        flag = "" if a == b else "   <- changed"
        print(f"  {domain + 's':<12} {a:>4} -> {b:<4}{flag}")
    print(f"  {'entities':<12} {len(old):>4} -> {len(new):<4}")

    added = sorted(set(new) - set(old))
    duplicates = [e for e in added if is_suffix_duplicate(e, old)]
    failed |= report("Removed entities", sorted(set(old) - set(new)))
    failed |= report("New '_N' duplicates", duplicates)
    report("Added entities", [e for e in added if e not in duplicates])
    failed |= report("Went unavailable or unknown", sorted(
        f"{e}  ({old[e]['state']} -> {new[e]['state']})"
        for e in set(old) & set(new)
        if new[e]["state"] in UNAVAILABLE and old[e]["state"] not in UNAVAILABLE))

    if args.states:
        watched = sorted(e for e in set(old) & set(new)
                         if any(fnmatch.fnmatch(e, glob) for glob in args.states))
        print(f"\nWatched states: {len(watched)} entities match {', '.join(args.states)}")
        failed |= report("State differences", [
            f"{e}  ({old[e]['state']} -> {new[e]['state']})"
            for e in watched if old[e]["state"] != new[e]["state"]])

    log_after = before.get("log_after")
    if log_after is None:
        print("\nLog check skipped: the HA log was not readable when the snapshot was taken.")
    else:
        try:
            entries = read_system_log()
        except CheckError as err:
            print(f"\nLog check skipped: {err}")
        else:
            hits = [
                f"{e['level']} {e['name']}: {message[:200]}"
                for e in entries if e["timestamp"] > log_after
                for message in e["message"] if LOG_PATTERN.search(message)]
            failed |= report("New log entries (duplicate / invalid config / setup failed)", hits)

    print("\nResult: " + ("DIFFERENCES FOUND" if failed else "no differences"))
    return 1 if failed else 0


def main(argv):
    parser = argparse.ArgumentParser(description="Read-only before/after check of the HA state machine.")
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot", help="record the current state")
    snap.add_argument("--out", help="snapshot file (default: %%TEMP%%\\ha_snapshot\\<timestamp>.json)")
    comp = sub.add_parser("compare", help="compare a snapshot with the live state or a second snapshot")
    comp.add_argument("before")
    comp.add_argument("after", nargs="?")
    comp.add_argument("--states", action="append", metavar="GLOB",
                      help="also compare the state of matching entities (repeatable)")
    args = parser.parse_args(argv[1:])
    try:
        return cmd_snapshot(args) if args.command == "snapshot" else cmd_compare(args)
    except CheckError as err:
        sys.stderr.write(f"Error: {err}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
