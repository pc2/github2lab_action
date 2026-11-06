# SPDX-FileCopyrightText: 2026 Gerrit Pape <gerrit.pape@uni-paderborn.de>
#
# SPDX-License-Identifier: MIT

"""Run the action scripts against mocked GitLab, GitHub and git commands."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40

# Answers GitLab and GitHub API calls from the JSON state file and logs every request.
CURL = r"""
import json
import os
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlparse

args = sys.argv[1:]
url = args[-1]
method = args[args.index("--request") + 1] if "--request" in args else "GET"
body = json.loads(args[args.index("--data") + 1]) if "--data" in args else None
form = [args[i + 1] for i, arg in enumerate(args) if arg == "--form-string"]
log = Path(os.environ["REQUEST_LOG"])
with log.open("a") as stream:
    stream.write(json.dumps(dict(url=url, method=method, body=body, form=form)) + "\n")
state = json.loads(Path(os.environ["STATE"]).read_text())
requests = [json.loads(line) for line in log.read_text().splitlines()]
path = urlparse(url).path
page = int(parse_qs(urlparse(url).query).get("page", ["1"])[0])


def fail(message):
    print(f"curl: (22) {message}", file=sys.stderr)
    sys.exit(22)


def paged(items):
    print(json.dumps(items[(page - 1) * 100:page * 100]))


if path.endswith("/trigger/pipeline"):
    attempts = sum(r["url"].endswith("/trigger/pipeline") for r in requests)
    if "trigger_response" in state:
        print(state["trigger_response"])
    elif attempts <= state.get("trigger_missing", 0):
        print('{"message":{"base":["Reference not found"]}}')
    else:
        print(json.dumps(state["pipeline"]))
elif path.endswith("/bridges"):
    pipeline = path.split("/pipelines/")[1].split("/")[0]
    paged(state.get("bridges", {}).get(pipeline, []))
elif path.endswith("/jobs"):
    pipeline = path.split("/pipelines/")[1].split("/")[0]
    paged(state.get("jobs", {}).get(pipeline, []))
elif "/pipelines/" in path:
    reads = sum("/pipelines/" in r["url"] and urlparse(r["url"]).path.split("/")[-2] == "pipelines"
                for r in requests)
    if 1 < reads <= state.get("poll_failures", 0) + 1:
        fail("The requested URL returned error: 502")
    if reads > 1 and "poll_response" in state:
        print(state["poll_response"])
    else:
        print(json.dumps(state["pipeline"]))
elif "/check-runs" in path and method == "GET":
    runs = state.get("check_runs", [])
    print(json.dumps({"check_runs": runs[(page - 1) * 100:page * 100]}))
elif "/check-runs" in path:
    print('{"id": 111}')
elif path.endswith("/projects/42"):
    print('{"http_url_to_repo": "https://git.example/example/project.git"}')
else:
    print("{}")
"""

# Logs git invocations and simulates pushes, including a locked remote branch.
GIT = r"""
import json
import os
from pathlib import Path
import sys

log = Path(os.environ["GIT_LOG"])
with log.open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
state = json.loads(Path(os.environ["STATE"]).read_text())
if sys.argv[1] == "push":
    pushes = sum(json.loads(line)[0] == "push" for line in log.read_text().splitlines())
    if pushes <= state.get("push_locked", 0):
        print("remote: error: cannot lock ref 'refs/heads/main': is at " + "b" * 40 + " but expected " + "c" * 40)
        sys.exit(1)
    print("Everything up-to-date")
    sys.exit(state.get("push_exit", 0))
if sys.argv[1] == "rev-parse":
    print("a" * 40)
"""

# Advances one hundred seconds per call, so deadlines pass without waiting.
DATE = """#!/bin/sh
value=$(cat "$DATE_FILE" 2>/dev/null || echo 0)
value=$((value + 100))
echo "$value" > "$DATE_FILE"
echo "$value"
"""

# Serves GitLab job lists and artifact downloads for get_artifact.py.
REQUESTS = r"""
import json
import os
from pathlib import Path


class Response:
    def __init__(self, payload=None, broken=False):
        self.payload, self.broken = payload, broken

    def json(self):
        return self.payload

    def raise_for_status(self):
        pass

    def iter_content(self, chunk_size):
        yield b"partial"
        if self.broken:
            raise ConnectionError("transfer interrupted")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def get(url, headers=None, params=None, stream=False, timeout=None):
    assert timeout, url
    with open(os.environ["REQUEST_LOG"], "a") as log:
        log.write(json.dumps(dict(url=url, params=params)) + "\n")
    state = json.loads(Path(os.environ["STATE"]).read_text())
    page = (params or {}).get("page", 1)
    for kind in ("jobs", "bridges"):
        if url.endswith(f"/{kind}"):
            pipeline = url.split("/pipelines/")[1].split("/")[0]
            items = state.get(kind, {}).get(pipeline, [])
            return Response(items[(page - 1) * 100:page * 100])
    assert url.endswith("/artifacts") and stream, url
    return Response(broken=url.split("/")[-2] in state.get("broken", []))
"""


def job(index, name, status="success", allow_failure=False):
    return {
        "id": index,
        "name": name,
        "status": status,
        "allow_failure": allow_failure,
        "stage": "test",
        "web_url": f"https://git.example/jobs/{index}",
        "duration": 60,
        "artifacts": [{"file_type": "archive", "file_format": "zip"}],
    }


class ScriptTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name, source in (("curl", CURL), ("git", GIT)):
            (bin_dir / name).write_text(f"#!{sys.executable}\n{source}")
        (bin_dir / "date").write_text(DATE)
        (bin_dir / "sleep").write_text("#!/bin/sh\nexit 0\n")
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        modules = self.root / "modules"
        modules.mkdir()
        (modules / "requests.py").write_text(REQUESTS)
        self.modules = modules
        self.state = {
            "pipeline": {
                "id": 123,
                "project_id": 42,
                "sha": SHA,
                "ref": "main",
                "status": "success",
                "web_url": "https://git.example/pipelines/123",
            },
            "jobs": {"123": [job(1, "tests")]},
        }
        self.env = dict(os.environ) | {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "STATE": str(self.root / "state.json"),
            "REQUEST_LOG": str(self.root / "requests.jsonl"),
            "GIT_LOG": str(self.root / "git.jsonl"),
            "DATE_FILE": str(self.root / "date"),
            "GITHUB_OUTPUT": str(self.root / "output"),
            "GITHUB_STEP_SUMMARY": str(self.root / "summary"),
            "RUNNER_TEMP": str(self.root),
            "TMPDIR": str(self.root),
            "GITLAB_HOSTNAME": "git.example",
            "GITLAB_PROJECT_ID": "42",
            "GITLAB_TOKEN": "read-token",
            "GITLAB_TRIGGER_TOKEN": "trigger-token",
            "GITHUB_TOKEN": "github-token",
            "GITHUB_REPOSITORY": "example/project",
            "GITHUB_EVENT_NAME": "workflow_dispatch",
            "GITHUB_SHA": SHA,
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REF_NAME": "main",
            "PIPELINE_ID": "123",
            "TARGET_SHA": SHA,
            "POLL_TIMEOUT": "0",
            "MAX_WAIT_MINUTES": "0",
            "CHECK_RUNS": "true",
            "CHECK_PREFIX": "gitlab/42/123/",
            "SUMMARY": "true",
            "LOG_TRACES": "false",
            "SET_STATUS": "false",
        }

    def tearDown(self):
        self.directory.cleanup()

    def run_script(self, script, **overrides):
        (self.root / "state.json").write_text(json.dumps(self.state))
        for name in ("requests.jsonl", "git.jsonl", "output", "summary", "date"):
            (self.root / name).write_text("")
        command = (
            [sys.executable, "-B", str(ROOT / script)]
            if script.endswith(".py")
            else ["sh", str(ROOT / script)]
        )
        env = self.env | overrides
        if script.endswith(".py"):
            env["PYTHONPATH"] = str(self.modules)
        return subprocess.run(
            command,
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
            timeout=60,
            check=False,
        )

    def requests(self):
        return [
            json.loads(line)
            for line in (self.root / "requests.jsonl").read_text().splitlines()
        ]

    def output(self):
        return (self.root / "output").read_text()

    def checks(self):
        return [
            r["body"]
            for r in self.requests()
            if "/check-runs" in r["url"] and r["method"] != "GET"
        ]


class MirrorTests(ScriptTest):
    def pushes(self):
        return [
            args
            for args in map(
                json.loads, (self.root / "git.jsonl").read_text().splitlines()
            )
            if args[0] == "push"
        ]

    def test_mirror_pushes_the_exact_commit_without_fetching_or_triggering(self):
        result = self.run_script(
            "mirror.sh",
            MIRROR_SHA=SHA,
            MIRROR_BRANCH="main",
            MIRROR_ONLY="true",
            FORCE_PUSH="true",
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(
            self.pushes(), [["push", "--force", "gitlab", f"{SHA}:refs/heads/main"]]
        )
        calls = [
            json.loads(line)[0]
            for line in (self.root / "git.jsonl").read_text().splitlines()
        ]
        self.assertFalse({"fetch", "checkout", "pull"} & set(calls))
        self.assertFalse(any(r["method"] == "POST" for r in self.requests()))

    def test_unchanged_branch_triggers_a_pipeline_unless_mirror_only(self):
        for mirror_only, triggers in (("", 1), ("false", 1), ("true", 0)):
            with self.subTest(mirror_only=mirror_only):
                result = self.run_script(
                    "mirror.sh", MIRROR_SHA=SHA, MIRROR_ONLY=mirror_only
                )
                self.assertEqual(result.returncode, 0, result.stdout)
                posts = [r for r in self.requests() if r["method"] == "POST"]
                self.assertEqual(len(posts), triggers)
                self.assertTrue(
                    all(r["url"].endswith("/projects/42/pipeline") for r in posts)
                )

    def test_failed_push_fails_the_mirror(self):
        self.state["push_exit"] = 1
        result = self.run_script("mirror.sh", MIRROR_SHA=SHA, MIRROR_ONLY="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.pushes()), 1)

    def test_push_rejected_by_a_locked_branch_is_retried(self):
        for locked, returncode, pushes in ((1, 0, 2), (9, 1, 5)):
            with self.subTest(locked=locked):
                self.state["push_locked"] = locked
                result = self.run_script(
                    "mirror.sh",
                    MIRROR_SHA=SHA,
                    MIRROR_BRANCH="main",
                    MIRROR_ONLY="true",
                    FORCE_PUSH="true",
                )
                self.assertEqual(
                    result.returncode != 0, bool(returncode), result.stdout
                )
                self.assertEqual(len(self.pushes()), pushes)


class TriggerTests(ScriptTest):
    def posts(self):
        return [r for r in self.requests() if r["method"] == "POST"]

    def test_trigger_starts_one_pipeline_with_variables(self):
        result = self.run_script(
            "trigger.sh",
            PIPELINE_REF="main",
            PIPELINE_VARIABLES=f"EXPECTED_COMMIT_SHA={SHA}\nX=a=b c",
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.posts()), 1)
        self.assertIn(f"variables[EXPECTED_COMMIT_SHA]={SHA}", self.posts()[0]["form"])
        self.assertIn("variables[X]=a=b c", self.posts()[0]["form"])
        self.assertIn("pipeline_id=123", self.output())

    def test_invalid_variables_send_no_request(self):
        result = self.run_script(
            "trigger.sh", PIPELINE_REF="main", PIPELINE_VARIABLES="invalid line"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests(), [])

    def test_trigger_retries_until_gitlab_knows_the_pushed_ref(self):
        self.state["trigger_missing"] = 1
        result = self.run_script("trigger.sh", PIPELINE_REF="main")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.posts()), 2)
        self.assertIn("pipeline_id=123", self.output())

    def test_trigger_fails_when_the_ref_never_appears(self):
        self.state["trigger_missing"] = 99
        result = self.run_script("trigger.sh", PIPELINE_REF="main")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Reference not found", result.stdout)
        self.assertNotIn("pipeline_id=", self.output())

    def test_other_trigger_errors_fail_without_retry(self):
        self.state["trigger_response"] = '{"message":"401 Unauthorized"}'
        result = self.run_script("trigger.sh", PIPELINE_REF="main")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.posts()), 1)


class StatusTests(ScriptTest):
    def test_terminal_states_report_completion_and_checks(self):
        for status, returncode in (
            ("success", 0),
            ("failed", 1),
            ("canceled", 1),
            ("skipped", 1),
        ):
            with self.subTest(status=status):
                self.state["pipeline"]["status"] = status
                self.state["jobs"] = {"123": [job(1, "tests", status)]}
                result = self.run_script("get_ci_state.sh")
                self.assertEqual(result.returncode, returncode, result.stdout)
                self.assertIn("finished=true", self.output())
                self.assertIn(f"status={status}", self.output())
                self.assertFalse(any("/statuses/" in r["url"] for r in self.requests()))
                checks = self.checks()
                self.assertEqual(
                    {c["name"] for c in checks},
                    {"gitlab/42/123/tests", "gitlab/42/123/pipeline"},
                )
                self.assertTrue(all(c["head_sha"] == SHA for c in checks))
                self.assertIn("tests", (self.root / "summary").read_text())

    def test_waiting_pipelines_hand_over_at_the_deadline(self):
        for status in (
            "created",
            "pending",
            "running",
            "waiting_for_resource",
            "manual",
            "scheduled",
            "canceling",
        ):
            with self.subTest(status=status):
                self.state["pipeline"]["status"] = status
                self.state["jobs"] = {"123": [job(1, "tests", status)]}
                result = self.run_script("get_ci_state.sh", MAX_WAIT_MINUTES="1")
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("finished=false", self.output())
                self.assertTrue(all(c["status"] != "completed" for c in self.checks()))

    def test_blocked_pipeline_finishes_when_stopping_on_manual_jobs(self):
        self.state["pipeline"]["status"] = "manual"
        self.state["jobs"] = {"123": [job(1, "tests"), job(2, "deploy", "manual")]}
        result = self.run_script(
            "get_ci_state.sh", STOP_ON_MANUAL="true", MAX_WAIT_MINUTES="30"
        )
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("finished=true", self.output())
        self.assertIn("status=manual", self.output())
        checks = {c["name"]: c for c in self.checks()}
        for name in ("gitlab/42/123/deploy", "gitlab/42/123/pipeline"):
            self.assertEqual(checks[name]["conclusion"], "action_required")
        self.assertEqual(checks["gitlab/42/123/tests"]["conclusion"], "success")

    def test_optional_manual_jobs_are_skipped(self):
        self.state["jobs"] = {"123": [job(1, "deploy", "manual", allow_failure=True)]}
        result = self.run_script("get_ci_state.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        check = next(c for c in self.checks() if c["name"].endswith("/deploy"))
        self.assertEqual(check["conclusion"], "skipped")

    def test_invalid_responses_never_report_completion(self):
        for status in (None, "unknown"):
            with self.subTest(status=status):
                self.state["pipeline"]["status"] = status
                result = self.run_script("get_ci_state.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("finished=true", self.output())

    def test_monitoring_survives_a_gitlab_outage(self):
        self.state["pipeline"]["status"] = "pending"
        self.state["poll_response"] = json.dumps(
            self.state["pipeline"] | {"status": "success"}
        )
        self.state["poll_failures"] = 3
        result = self.run_script("get_ci_state.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("finished=true", self.output())
        self.assertIn("retrying", result.stdout)

    def test_outage_reaching_the_deadline_hands_over(self):
        self.state["pipeline"]["status"] = "pending"
        self.state["poll_failures"] = 1000
        result = self.run_script("get_ci_state.sh", MAX_WAIT_MINUTES="30")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("finished=false", self.output())

    def test_outage_without_deadline_fails_after_the_failure_window(self):
        self.state["pipeline"]["status"] = "pending"
        self.state["poll_failures"] = 1000
        result = self.run_script("get_ci_state.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("finished=", self.output())
        self.assertIn("for 30 minutes", result.stdout)

    def test_outage_at_startup_hands_over_without_checks(self):
        self.state["pipeline"]["status"] = "unknown"
        result = self.run_script("get_ci_state.sh", MAX_WAIT_MINUTES="30")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("finished=false", self.output())
        self.assertFalse(any("/check-runs" in r["url"] for r in self.requests()))

    def test_checks_cover_all_pages_and_child_pipelines(self):
        self.state["jobs"] = {
            "123": [job(i, "tests" if i == 0 else f"matrix {i}") for i in range(150)],
            "456": [job(1000, "tests")],
        }
        self.state["bridges"] = {
            "123": [
                {"name": "child", "downstream_pipeline": {"id": 456, "project_id": 42}},
                {"name": "other", "downstream_pipeline": {"id": 789, "project_id": 7}},
            ]
        }
        result = self.run_script("get_ci_state.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        names = {c["name"] for c in self.checks()}
        self.assertEqual(len(names), 152)
        self.assertLessEqual(
            {"gitlab/42/123/matrix 149", "gitlab/42/123/child/tests"}, names
        )
        self.assertFalse(any("/pipelines/789/" in r["url"] for r in self.requests()))

    def test_existing_checks_are_updated_across_pages(self):
        self.state["check_runs"] = [
            {"id": index, "name": f"other/{index}"} for index in range(99)
        ] + [{"id": 500, "name": "gitlab/42/123/tests"}]
        result = self.run_script("get_ci_state.sh")
        self.assertEqual(result.returncode, 0, result.stdout)
        updates = [r for r in self.requests() if r["method"] == "PATCH"]
        self.assertTrue(any(r["url"].endswith("/check-runs/500") for r in updates))


class ArtifactTests(ScriptTest):
    def setUp(self):
        super().setUp()
        self.state["jobs"] = {
            "123": [job(i, f"job {i}") for i in range(150)],
            "456": [job(1000, "job 0")],
        }
        self.state["bridges"] = {
            "123": [
                {"name": "child", "downstream_pipeline": {"id": 456, "project_id": 42}},
                {"name": "other", "downstream_pipeline": {"id": 789, "project_id": 7}},
            ]
        }
        self.artifacts = self.root / "collected"

    def test_collection_covers_all_pages_and_child_pipelines(self):
        result = self.run_script("get_artifact.py", ARTIFACT_DIR=str(self.artifacts))
        self.assertEqual(result.returncode, 0, result.stderr)
        files = {path.name for path in self.artifacts.iterdir()}
        self.assertEqual(len(files), 151)
        self.assertLessEqual({"job_149.zip", "child_job_0.zip"}, files)

    def test_interrupted_transfer_leaves_no_partial_archive(self):
        self.state["broken"] = ["7"]
        result = self.run_script("get_artifact.py", ARTIFACT_DIR=str(self.artifacts))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("transfer interrupted", result.stderr)
        self.assertFalse((self.artifacts / "job_7.zip").exists())

    def test_colliding_archive_names_fail_the_collection(self):
        self.state["jobs"] = {"123": [job(1, "a/b"), job(2, "a b")]}
        self.state["bridges"] = {}
        result = self.run_script("get_artifact.py", ARTIFACT_DIR=str(self.artifacts))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("share the artifact name", result.stderr)


if __name__ == "__main__":
    unittest.main()
