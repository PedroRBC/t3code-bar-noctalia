import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "t3code-bar" / "scripts" / "t3bar.py"
ENV_ID = "env-1"
DEAD_PID = 2**30  # above Linux pid_max, so kill() always reports ESRCH

# Column lists copied from T3 Code 0.1.8 statev2.sqlite (indexes and triggers omitted).
SCHEMA = """
CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
  title TEXT NOT NULL, default_provider TEXT NOT NULL, runtime_mode TEXT NOT NULL,
  interaction_mode TEXT NOT NULL, active_provider_thread_id TEXT, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, archived_at TEXT, deleted_at TEXT, payload_json TEXT NOT NULL,
  provider_instance_id TEXT);
CREATE TABLE orchestration_v2_projection_runs (run_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL, provider TEXT NOT NULL, provider_thread_id TEXT, status TEXT NOT NULL,
  requested_at TEXT NOT NULL, completed_at TEXT, payload_json TEXT NOT NULL, provider_instance_id TEXT);
CREATE TABLE orchestration_v2_projection_runtime_requests (runtime_request_id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL, node_id TEXT NOT NULL, provider_turn_id TEXT, kind TEXT NOT NULL,
  status TEXT NOT NULL, created_at TEXT NOT NULL, resolved_at TEXT, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_plans (plan_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  run_id TEXT, node_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY,
  thread_id TEXT, owner_node_id TEXT, provider TEXT NOT NULL, provider_session_id TEXT,
  status TEXT NOT NULL, first_run_ordinal INTEGER, last_run_ordinal INTEGER, updated_at TEXT NOT NULL,
  payload_json TEXT NOT NULL, driver TEXT, provider_instance_id TEXT);
CREATE TABLE orchestration_v2_projection_messages (message_id TEXT PRIMARY KEY, thread_id TEXT NOT NULL,
  run_id TEXT, node_id TEXT, role TEXT NOT NULL, streaming INTEGER NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, payload_json TEXT NOT NULL);
CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL,
  workspace_root TEXT NOT NULL, scripts_json TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT);
"""


def ts(minute):
    """Minute offset -> ISO timestamp on a fixed synthetic day."""
    return f"2026-01-01T{10 + minute // 60:02d}:{minute % 60:02d}:00.000Z"


def epoch_ms(minute):
    return 1767261600000 + minute * 60000  # 2026-01-01T10:00Z


class Fixture:
    def __init__(self, home, schema=SCHEMA):
        self.userdata = Path(home) / "userdata"
        self.userdata.mkdir(parents=True)
        self.db = sqlite3.connect(self.userdata / "statev2.sqlite")
        self.db.executescript(schema)
        self.db.execute("INSERT INTO projection_projects VALUES ('p1','Demo','/w','[]',?,?,NULL)",
                        (ts(0), ts(0)))
        (self.userdata / "environment-id").write_text(ENV_ID + "\n")
        self.runtime(os.getpid())
        self.runs = 0

    def runtime(self, pid, port=3773):
        (self.userdata / "server-runtime.json").write_text(
            json.dumps({"pid": pid, "port": port, "serverVersion": "0.1.8-test"}))

    def thread(self, tid, updated=1, created=0, mode="default", archived=None, deleted=None,
               pt=None, **payload):
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (tid, "p1", f"Title {tid}", "claudeAgent", "full", mode, pt, ts(created), ts(updated),
             archived, deleted, json.dumps({"lineage": {}, "branch": "main", **payload}), "claudeAgent"))

    def run(self, tid, status, started=1, completed=None, message=None):
        self.runs += 1
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_runs VALUES (?,?,?,?,?,?,?,?,?,?)",
            (f"r{self.runs}", tid, self.runs, "claudeAgent", None, status, ts(started),
             ts(completed) if completed is not None else None,
             json.dumps({"startedAt": ts(started), "userMessageId": message}), "claudeAgent"))

    def request(self, tid, kind, created=2, status="pending"):
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_runtime_requests VALUES (?,?,?,?,?,?,?,?,?)",
            (f"q-{tid}-{kind}", tid, "n", None, kind, status, ts(created), None, "{}"))

    def provider_thread(self, ptid, tid, status="active", goal=None, driver="codex"):
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (ptid, tid, None, driver, None, status, 1, 1, ts(1),
             json.dumps({"status": status, "goal": goal}), driver, driver))

    def plan(self, tid, kind="proposed_plan", status="active"):
        self.db.execute("INSERT INTO orchestration_v2_projection_plans VALUES (?,?,?,?,?,?,?)",
                        (f"plan-{tid}", tid, None, "n", kind, status, "{}"))

    def message(self, mid, tid, updated, **payload):
        self.db.execute("INSERT INTO orchestration_v2_projection_messages VALUES (?,?,?,?,?,?,?,?,?)",
                        (mid, tid, None, None, "user", 0, ts(updated), ts(updated), json.dumps(payload)))

    def call(self, *args):
        self.db.commit()
        proc = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "threads", *args], capture_output=True, text=True,
            env={**os.environ, "T3CODE_HOME": str(self.userdata.parent)}, timeout=10)
        assert proc.returncode == 0 and not proc.stderr, proc.stderr
        return json.loads(proc.stdout)


class ThreadsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fx = Fixture(self.tmp.name)
        self.addCleanup(self.fx.db.close)

    def by_id(self, result):
        return {t["id"]: t for t in result["threads"]}

    def test_each_status(self):
        fx = self.fx
        fx.thread("approval"); fx.run("approval", "running"); fx.request("approval", "command", created=7)
        fx.thread("input"); fx.request("input", "user_input", created=8)
        fx.thread("connecting"); fx.run("connecting", "starting", started=9)
        fx.thread("working"); fx.run("working", "running", started=11)
        fx.provider_thread("pt-goal", "goal", goal={"status": "active"})
        fx.thread("goal", pt="pt-goal"); fx.run("goal", "waiting", started=12)
        fx.thread("failed"); fx.run("failed", "failed", started=3, completed=4)
        fx.provider_thread("pt-err", "session-error", status="error")
        fx.thread("session-error", pt="pt-err")
        fx.thread("plan", mode="plan", lastVisitedAt=ts(30)); fx.plan("plan")
        fx.run("plan", "completed", started=3, completed=5)
        fx.thread("done", lastVisitedAt=ts(4)); fx.run("done", "completed", started=3, completed=5)
        fx.thread("idle", lastVisitedAt=ts(6)); fx.run("idle", "completed", started=3, completed=5)
        fx.thread("never-visited"); fx.run("never-visited", "completed", started=3, completed=5)
        fx.thread("silent"); fx.message("m-compact", "silent", 2, text=" /compact ", idleCompaction={})
        fx.run("silent", "running", message="m-compact")
        result = fx.call("--latest", "50")
        threads = self.by_id(result)
        expected = {"approval": "approval", "input": "input", "connecting": "connecting",
                    "working": "working", "goal": "goal", "failed": "failed",
                    "session-error": "failed", "plan": "planReady", "done": "done", "idle": "idle",
                    "never-visited": "idle", "silent": "idle"}
        self.assertEqual({k: threads[k]["status"] for k in expected}, expected)
        self.assertEqual(result["counts"], {"waiting": 2, "working": 3})
        self.assertEqual(threads["approval"]["since"], epoch_ms(7))
        self.assertEqual(threads["working"]["since"], epoch_ms(11))
        self.assertEqual(threads["goal"]["provider"], "codex")
        self.assertEqual(threads["done"]["since"], epoch_ms(1))  # updated_at: no user message
        self.assertEqual(threads["done"]["lastActivityAt"], epoch_ms(5))
        self.assertTrue(result["ok"])
        self.assertIsNone(result["error"])
        self.assertEqual(result["serverVersion"], "0.1.8-test")

    def test_group_order_and_pins(self):
        fx = self.fx
        fx.thread("pin-b", pinnedAt=ts(1), pinOrderKey="a1")
        fx.thread("pin-a", pinnedAt=ts(1), pinOrderKey="a0")
        fx.thread("pin-old", created=1, pinnedAt=ts(1))
        fx.thread("pin-new", created=2, pinnedAt=ts(1))
        fx.thread("pin-approval", pinnedAt=ts(1), pinOrderKey="a2")
        fx.request("pin-approval", "command")
        fx.thread("wait-old", updated=2); fx.request("wait-old", "user_input")
        fx.thread("wait-new", updated=9); fx.request("wait-new", "command")
        fx.thread("work-old", updated=3); fx.run("work-old", "running", started=3)
        fx.thread("work-new", updated=4); fx.run("work-new", "preparing", started=8)
        fx.thread("late-old", updated=5)
        fx.thread("late-new", updated=6)
        fx.thread("late-msg", updated=1); fx.message("m1", "late-msg", 7, text="hi")
        result = fx.call()
        self.assertEqual([t["id"] for t in result["threads"]], [
            "pin-a", "pin-b", "pin-approval", "pin-new", "pin-old",
            "wait-new", "wait-old", "work-new", "work-old", "late-msg", "late-new", "late-old"])
        pin = self.by_id(result)["pin-approval"]
        self.assertEqual((pin["group"], pin["status"], pin["pinned"]), ("pinned", "approval", True))
        self.assertEqual(result["counts"], {"waiting": 3, "working": 2})
        hidden = fx.call("--latest", "0")
        self.assertEqual([t["id"] for t in hidden["threads"]], [
            "pin-a", "pin-b", "pin-approval", "pin-new", "pin-old",
            "wait-new", "wait-old", "work-new", "work-old"])
        self.assertEqual(hidden["counts"], result["counts"])

    def test_filters(self):
        fx = self.fx
        fx.thread("visible")
        fx.thread("deleted", deleted=ts(2))
        fx.thread("archived", archived=ts(2))
        fx.thread("subagent", lineage={"relationshipToParent": "subagent"})
        fx.thread("side", lineage={"sideChat": True})
        fx.thread("thread:legacy")
        fx.thread("fork", lineage={"relationshipToParent": "fork"})
        self.assertEqual(sorted(self.by_id(fx.call())), ["fork", "visible"])

    def test_subagent_request_surfaces_on_root(self):
        fx = self.fx
        fx.thread("root"); fx.run("root", "running")
        fx.thread("child", lineage={"relationshipToParent": "subagent", "rootThreadId": "root"})
        fx.thread("grandchild", lineage={"relationshipToParent": "subagent", "rootThreadId": "root"})
        fx.request("grandchild", "command")
        fx.thread("asker"); fx.thread("side", lineage={"sideChat": True, "rootThreadId": "asker"})
        fx.request("side", "user_input")
        threads = self.by_id(fx.call())
        self.assertEqual(sorted(threads), ["asker", "root"])
        self.assertEqual(threads["root"]["status"], "approval")
        self.assertEqual(threads["asker"]["status"], "idle")  # side chats do not roll up

    def test_latest_limit_and_clamp(self):
        for i in range(55):
            self.fx.thread(f"t{i:02d}", updated=i)
        self.assertEqual([t["id"] for t in self.fx.call("--latest", "2")["threads"]], ["t54", "t53"])
        self.assertEqual(len(self.fx.call()["threads"]), 10)
        self.assertEqual(len(self.fx.call("--latest", "99")["threads"]), 50)
        self.assertEqual(self.fx.call("--latest", "-3")["threads"], [])

    def test_hide_settled_uses_explicit_marker_before_latest_limit(self):
        fx = self.fx
        fx.thread("idle", updated=1)
        fx.thread("active-override", updated=2, settledOverride="active")
        fx.thread("settled", updated=9, settledOverride="settled")
        fx.thread("settled-pin", pinnedAt=ts(1), settledOverride="settled")
        fx.thread("working"); fx.run("working", "running")
        fx.thread("waiting"); fx.request("waiting", "command")
        self.assertIn("settled", self.by_id(fx.call()))
        self.assertIn("settled-pin", self.by_id(fx.call()))
        hidden = fx.call("--hide-settled", "--latest", "2")
        self.assertEqual(set(self.by_id(hidden)), {"idle", "active-override", "working", "waiting"})
        self.assertEqual(hidden["counts"], {"waiting": 1, "working": 1})

    def test_offline_and_missing_runtime(self):
        self.fx.thread("a")
        self.fx.runtime(DEAD_PID)
        result = self.fx.call()
        self.assertFalse(result["online"])
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["threads"]), 1)
        (self.fx.userdata / "server-runtime.json").unlink()
        result = self.fx.call()
        self.assertFalse(result["online"])
        self.assertIsNone(result["threads"][0]["browserUrl"])
        self.assertTrue(result["threads"][0]["openUrl"].startswith("t3code://threads/"))

    def test_online_with_live_pid(self):
        self.assertTrue(self.fx.call()["online"])

    def test_url_encoding(self):
        (self.fx.userdata / "environment-id").write_text("env/1 #%\n")
        self.fx.thread("a b/c?")
        thread = self.fx.call()["threads"][0]
        self.assertEqual(thread["openUrl"], "t3code://threads/env%2F1%20%23%25/a%20b%2Fc%3F")
        self.assertEqual(thread["browserUrl"], "http://127.0.0.1:3773/env%2F1%20%23%25/a%20b%2Fc%3F")

    def test_invalid_timestamps_do_not_crash(self):
        self.fx.db.execute(
            "INSERT INTO orchestration_v2_projection_threads VALUES "
            "('bad','p1','T','codex','full','default',NULL,'garbage','',NULL,NULL,'{}',NULL)")
        thread = self.fx.call()["threads"][0]
        self.assertEqual((thread["status"], thread["lastActivityAt"], thread["since"]), ("idle", None, None))
        self.assertEqual(thread["branch"], None)

    def test_malformed_payload_is_invalid_data(self):
        self.fx.db.execute(
            "INSERT INTO orchestration_v2_projection_threads VALUES "
            "('bad','p1','T','codex','full','default',NULL,'x','x',NULL,NULL,'not json',NULL)")
        result = self.fx.call()
        self.assertEqual((result["ok"], result["error"], result["threads"]), (False, "invalidData", []))


class ErrorTests(unittest.TestCase):
    def test_missing_db(self):
        with tempfile.TemporaryDirectory() as home:
            proc = subprocess.run([sys.executable, "-I", str(SCRIPT), "threads"], capture_output=True,
                                  text=True, env={**os.environ, "T3CODE_HOME": home}, timeout=10)
        self.assertEqual(proc.returncode, 0)
        result = json.loads(proc.stdout)
        self.assertEqual((result["ok"], result["error"], result["online"]), (False, "missing", False))
        self.assertEqual(result["counts"], {"waiting": 0, "working": 0})

    def test_missing_column_is_incompatible_schema(self):
        with tempfile.TemporaryDirectory() as home:
            fx = Fixture(home, SCHEMA.replace("interaction_mode TEXT NOT NULL,", ""))
            try:
                result = fx.call()
            finally:
                fx.db.close()
        self.assertEqual((result["ok"], result["error"]), (False, "incompatibleSchema"))

    def test_missing_table_is_incompatible_schema(self):
        schema = SCHEMA.replace("orchestration_v2_projection_plans (", "other_plans (")
        with tempfile.TemporaryDirectory() as home:
            fx = Fixture(home, schema)
            try:
                result = fx.call()
            finally:
                fx.db.close()
        self.assertEqual(result["error"], "incompatibleSchema")


if __name__ == "__main__":
    unittest.main()
