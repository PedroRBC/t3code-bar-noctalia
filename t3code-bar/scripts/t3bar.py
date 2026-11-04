#!/usr/bin/env python3
"""T3 Code Bar helper: print a read-only JSON snapshot of T3 Code threads.

Usage: t3bar.py threads [--latest N] [--hide-settled]
Reads ${T3CODE_HOME:-~/.t3}/userdata/{statev2.sqlite,server-runtime.json,environment-id}.
Never writes to T3 Code's files. Soft errors exit 0 with "error" set in the JSON.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sqlite3
import sys
from urllib.parse import quote

ACTIVE_RUN = "('preparing', 'starting', 'running', 'waiting')"

# Mirrors T3's isSilentShellRun: an idle "/compact" run is never shown as activity.
# shortcut: skips T3's failed-compaction and attachment checks and its full Unicode trim;
# upgrade if compaction runs start showing as Working.
SILENT = """({r}.status <> 'failed' AND EXISTS (
    SELECT 1 FROM orchestration_v2_projection_messages pm
    WHERE pm.message_id = json_extract({r}.payload_json, '$.userMessageId') AND pm.role = 'user'
      AND lower(trim(json_extract(pm.payload_json, '$.text'), char(9, 10, 13, 32))) = '/compact'
      AND (json_extract(pm.payload_json, '$.idleCompaction') IS NOT NULL
           OR (json_extract(pm.payload_json, '$.createdBy') = 'agent'
               AND json_extract(pm.payload_json, '$.creationSource') = 'server'))))"""

# Like T3's pendingSubagentRequest: a subagent's pending request (nested too) surfaces on its root thread.
PENDING = """(SELECT MAX(q.created_at) FROM orchestration_v2_projection_runtime_requests q
     JOIN orchestration_v2_projection_threads s ON s.thread_id = q.thread_id
     WHERE q.status = 'pending' AND q.kind {op} 'user_input'
       AND (s.thread_id = t.thread_id
            OR (json_extract(s.payload_json, '$.lineage.rootThreadId') = t.thread_id
                AND json_extract(s.payload_json, '$.lineage.relationshipToParent') = 'subagent')))"""

QUERY = f"""
SELECT
  t.thread_id AS id, t.title, p.title AS project, t.created_at, t.updated_at, t.interaction_mode AS mode,
  json_extract(t.payload_json, '$.branch') AS branch,
  json_extract(t.payload_json, '$.pinnedAt') AS pinned_at,
  json_extract(t.payload_json, '$.pinOrderKey') AS pin_key,
  json_extract(t.payload_json, '$.lastVisitedAt') AS visited_at,
  COALESCE(pt.driver, t.default_provider) AS provider,
  pt.status AS session_status,
  json_extract(pt.payload_json, '$.goal.status') AS goal_status,
  ar.status AS active_status,
  COALESCE(json_extract(ar.payload_json, '$.workStartedAt'),
           json_extract(ar.payload_json, '$.startedAt'), ar.requested_at) AS active_started_at,
  lr.status AS latest_status,
  COALESCE(json_extract(lr.payload_json, '$.startedAt'), lr.requested_at) AS latest_started_at,
  lr.completed_at AS latest_completed_at,
  {PENDING.format(op="<>")} AS approval_at,
  {PENDING.format(op="=")} AS input_at,
  EXISTS (SELECT 1 FROM orchestration_v2_projection_plans pl
     WHERE pl.thread_id = t.thread_id AND pl.kind = 'proposed_plan' AND pl.status = 'active') AS has_plan,
  (SELECT MAX(m.updated_at) FROM orchestration_v2_projection_messages m
     WHERE m.thread_id = t.thread_id AND m.role = 'user') AS user_message_at
FROM orchestration_v2_projection_threads t
LEFT JOIN projection_projects p ON p.project_id = t.project_id
LEFT JOIN orchestration_v2_projection_provider_threads pt
  ON pt.provider_thread_id = t.active_provider_thread_id
LEFT JOIN orchestration_v2_projection_runs ar ON ar.run_id = (
  SELECT r.run_id FROM orchestration_v2_projection_runs r
  WHERE r.thread_id = t.thread_id AND r.status IN {ACTIVE_RUN} AND NOT {SILENT.format(r="r")}
  ORDER BY r.ordinal DESC, r.run_id DESC LIMIT 1)
-- Latest executed run: the one that ended last (T3's latestExecutedRun).
LEFT JOIN orchestration_v2_projection_runs lr ON lr.run_id = (
  SELECT r.run_id FROM orchestration_v2_projection_runs r
  WHERE r.thread_id = t.thread_id AND r.status <> 'queued'
    AND NOT (r.status = 'cancelled' AND json_extract(r.payload_json, '$.startedAt') IS NULL)
    AND NOT {SILENT.format(r="r")}
  ORDER BY r.completed_at IS NULL DESC, r.completed_at DESC, r.ordinal DESC, r.run_id DESC LIMIT 1)
WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
  AND t.thread_id NOT LIKE 'thread:%'
  AND json_extract(t.payload_json, '$.lineage.sideChat') IS NOT 1
  AND json_extract(t.payload_json, '$.lineage.relationshipToParent') IS NOT 'subagent'
"""

WAITING = ("approval", "input")
WORKING = ("connecting", "goal", "working")
GROUPS = ("pinned", "waiting", "working", "latest")


class SoftError(Exception):
    pass


def ms(value):
    """ISO-8601 text -> epoch ms, or None when missing/invalid."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp() * 1000)


def read_text(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return ""


def read_runtime(path):
    try:
        data = json.loads(read_text(path) or "null")
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def int_field(data, key, low, high):
    value = data.get(key)
    return value if type(value) is int and low <= value <= high else None


def is_online(pid):
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
    except (OSError, OverflowError):
        # ESRCH: gone. EPERM: the pid now belongs to another user, so it is not our T3 server.
        return False
    return True


def status_of(row):
    if row["approval_at"] is not None:
        return "approval"
    if row["input_at"] is not None:
        return "input"
    if row["active_status"] in ("preparing", "starting"):
        return "connecting"
    if row["active_status"] in ("running", "waiting"):
        return "goal" if row["goal_status"] == "active" else "working"
    if row["latest_status"] == "failed" or row["session_status"] == "error":
        return "failed"
    if row["mode"] == "plan" and row["has_plan"]:
        return "planReady"
    completed, visited = ms(row["latest_completed_at"]), ms(row["visited_at"])
    # Like T3's sidebar: a completion is unseen only after a known last visit.
    if row["latest_status"] == "completed" and completed and visited and completed > visited:
        return "done"
    return "idle"


def read_threads(db_path, hide_settled=False):
    if not db_path.is_file():
        raise SoftError("missing")
    try:
        # mode=ro (not immutable) so the live WAL stays visible; timeout = busy_timeout 250 ms.
        conn = sqlite3.connect(f"file:{quote(str(db_path))}?mode=ro", uri=True, timeout=0.25)
        conn.row_factory = sqlite3.Row
        try:
            query = QUERY
            if hide_settled:
                query += " AND json_extract(t.payload_json, '$.settledOverride') IS NOT 'settled'"
            return conn.execute(query).fetchall()
        finally:
            conn.close()
    except sqlite3.Error as error:
        code = (getattr(error, "sqlite_errorcode", 0) or 0) & 0xFF
        if str(error).startswith("no such"):
            raise SoftError("incompatibleSchema") from None
        if code in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
            raise SoftError("busy") from None
        if code in (sqlite3.SQLITE_CANTOPEN, sqlite3.SQLITE_PERM, sqlite3.SQLITE_AUTH,
                    sqlite3.SQLITE_IOERR):
            raise SoftError("unavailable") from None
        raise SoftError("invalidData") from None


def text(value):
    return value if isinstance(value, str) and value else None


def build_threads(rows, latest, env_id, port):
    groups = {group: [] for group in GROUPS}
    counts = {"waiting": 0, "working": 0}
    for row in rows:
        thread_id = text(row["id"])
        if thread_id is None:
            raise SoftError("invalidData")
        status = status_of(row)
        times = [ms(row[key]) for key in ("updated_at", "active_started_at", "latest_started_at",
                                          "latest_completed_at", "user_message_at")]
        activity = max((t for t in times if t is not None), default=None)
        since = ms(row["approval_at"] if status == "approval" else row["input_at"] if status == "input"
                   else row["active_started_at"] if status in WORKING else None)
        if status not in WAITING + WORKING:
            # Same time T3's sidebar shows: latest user message, else thread updatedAt.
            since = ms(row["user_message_at"]) or ms(row["updated_at"])
        pinned = row["pinned_at"] is not None
        if pinned:
            group, pin_key = "pinned", text(row["pin_key"])
            sort_key = (pin_key is None, pin_key or "", -(ms(row["created_at"]) or 0), thread_id)
        else:
            group = "waiting" if status in WAITING else "working" if status in WORKING else "latest"
            sort_key = (-(activity or 0), thread_id)
        counts["waiting"] += status in WAITING
        counts["working"] += status in WORKING
        path = f"{quote(env_id, safe='')}/{quote(thread_id, safe='')}" if env_id else None
        groups[group].append((sort_key, {
            "id": thread_id,
            "title": text(row["title"]) or "",
            "projectName": text(row["project"]),
            "branch": text(row["branch"]),
            "provider": text(row["provider"]),
            "status": status,
            "group": group,
            "pinned": pinned,
            "since": since if since is not None else activity,
            "lastActivityAt": activity,
            "openUrl": f"t3code://threads/{path}" if path else None,
            "browserUrl": f"http://127.0.0.1:{port}/{path}" if path and port else None,
        }))
    threads = []
    for group in GROUPS:
        ordered = [item for _, item in sorted(groups[group], key=lambda pair: pair[0])]
        threads += ordered[:latest] if group == "latest" else ordered
    return threads, counts


def threads_snapshot(latest, hide_settled=False):
    home = os.environ.get("T3CODE_HOME", "").strip()
    userdata = Path(home or "~/.t3").expanduser() / "userdata"
    runtime = read_runtime(userdata / "server-runtime.json")
    version = runtime.get("serverVersion")
    result = {
        "ok": True,
        "error": None,
        "online": is_online(int_field(runtime, "pid", 1, 2**31 - 1)),
        "serverVersion": version if isinstance(version, str) else None,
        "counts": {"waiting": 0, "working": 0},
        "threads": [],
    }
    try:
        rows = read_threads(userdata / "statev2.sqlite", hide_settled)
        result["threads"], result["counts"] = build_threads(
            rows, latest, read_text(userdata / "environment-id"), int_field(runtime, "port", 1, 65535))
    except SoftError as error:
        result.update(ok=False, error=str(error))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    threads = sub.add_parser("threads")
    threads.add_argument("--latest", type=int, default=10)
    threads.add_argument("--hide-settled", action="store_true")
    args = parser.parse_args(argv)
    result = threads_snapshot(max(0, min(50, args.latest)), args.hide_settled)
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
