#!/usr/bin/env python3
"""release-plan.py against a scratch git repo and fixture release and run JSON.

usage: python3 -I scripts/fork/test_release_plan.py
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("release-plan.py")
spec = importlib.util.spec_from_file_location("release_plan", SCRIPT)
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


def release(tag, at):
    return {"tagName": tag, "publishedAt": at, "isDraft": False, "isPrerelease": False}


def run(run_id, sha, at, **jobs):
    names = {"meta": "Version and flavors", "chromium": "Build chromium", "webkit": "Build webkit"}
    return {"databaseId": run_id, "headSha": sha, "createdAt": at,
            "jobs": [{"name": names[k], "conclusion": v} for k, v in jobs.items()]}


class Scratch:
    """A canary checkout with an upstream branch merged in, in a temp dir."""

    def __init__(self, test):
        tmp = tempfile.TemporaryDirectory()
        test.addCleanup(tmp.cleanup)
        self.dir = tmp.name
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env = env | {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                          "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                          "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        self.git("init", "-q", "-b", "canary")
        self.commit("Sources/App.swift", "app")
        self.git("branch", "upstream")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.dir, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, path, text, branch="canary"):
        if branch != "canary":
            self.git("checkout", "-q", branch)
        file = Path(self.dir, path)
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        self.git("add", path)
        self.git("commit", "-q", "-m", path)
        if branch != "canary":
            self.git("checkout", "-q", "canary")
        return self.git("rev-parse", branch)

    def merge_upstream(self):
        self.git("merge", "-q", "--no-edit", "upstream")
        return self.head()

    def tag(self, name, sha=None):
        self.git("tag", name, sha or self.head())

    def head(self):
        return self.git("rev-parse", "HEAD")

    def sync(self, releases, runs=(), upstream="0.51.0"):
        """The sync decision as the workflow runs it: through the CLI."""
        files = {}
        for name, data in (("releases", releases), ("runs", list(runs))):
            files[name] = Path(self.dir, f".{name}.json")
            files[name].write_text(json.dumps(data))
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "sync", "--releases", str(files["releases"]),
                              "--runs", str(files["runs"]), "--head", self.head(), "--upstream", upstream,
                              "--upstream-ref", "upstream"],
                             cwd=self.dir, env=self.env, check=True, capture_output=True, text=True).stdout
        return json.loads(out)


def reasons(result):
    return {f["flavor"]: (f["release"], f["reason"]) for f in result["flavors"]}


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.repo = Scratch(self)

    def test_fresh_repo_releases_both(self):
        result = self.repo.sync([])
        self.assertEqual(result["engines"], "all")
        self.assertEqual(reasons(result)["webkit"], (True, "no release yet"))

    def test_both_current_releases_nothing(self):
        self.repo.tag("v0.51.0-r1")
        self.repo.tag("v0.51.0-r1-webkit")
        result = self.repo.sync([release("v0.51.0-r1", "2026-11-20T01"), release("v0.51.0-r1-webkit", "2026-11-20T02")])
        self.assertEqual(result["engines"], "none")
        self.assertIn("canary's head", reasons(result)["chromium"][1])

    def test_upstream_bump_releases_both(self):
        self.repo.tag("v0.51.0-r1")
        self.repo.tag("v0.51.0-r1-webkit")
        result = self.repo.sync([release("v0.51.0-r1", "2026-11-20T01"), release("v0.51.0-r1-webkit", "2026-11-20T02")],
                                upstream="0.51.1")
        self.assertEqual(result["engines"], "all")
        self.assertEqual(reasons(result)["chromium"], (True, "upstream 0.51.0 -> 0.51.1 since v0.51.0-r1"))

    def test_fork_change_releases_both(self):
        self.repo.tag("v0.51.0-r1")
        self.repo.tag("v0.51.0-r1-webkit")
        self.repo.commit("Sources/Other.swift", "fork")
        result = self.repo.sync([release("v0.51.0-r1", "2026-11-20T01"), release("v0.51.0-r1-webkit", "2026-11-20T02")])
        self.assertEqual(result["engines"], "all")
        self.assertEqual(reasons(result)["webkit"], (True, "fork changes since v0.51.0-r1-webkit: 1"))

    def test_docs_ci_and_upstream_commits_release_nothing(self):
        self.repo.tag("v0.51.0-r1")
        self.repo.tag("v0.51.0-r1-webkit")
        self.repo.commit("docs/x.md", "doc")
        self.repo.commit(".github/workflows/x.yml", "ci")
        self.repo.commit("Sources/Up.swift", "upstream", branch="upstream")
        self.repo.merge_upstream()
        result = self.repo.sync([release("v0.51.0-r1", "2026-11-20T01"), release("v0.51.0-r1-webkit", "2026-11-20T02")])
        self.assertEqual(result["engines"], "none")

    def test_chromium_missing_at_head(self):
        # The 0.51.0 case: both flavors' run cancelled at an older commit, then a WebKit-only run at head.
        self.repo.tag("v0.50.2-r1")
        self.repo.tag("v0.50.2-r1-webkit")
        older = self.repo.commit("Sources/Pane.swift", "rename")
        self.repo.commit("Sources/Up.swift", "0.51", branch="upstream")
        head = self.repo.merge_upstream()
        self.repo.tag("v0.51.0-r1-webkit")
        releases = [release("v0.50.2-r1", "2026-11-20T06:12"), release("v0.50.2-r1-webkit", "2026-11-20T06:59"),
                    release("v0.51.0-r1-webkit", "2026-11-21T01:57"),
                    release("v0.47.19-202611191115", "2026-11-19T15:57"), release("cef-patched-1", "2026-11-22")]
        runs = [run(2, head, "2026-11-20T22", meta="success", webkit="success"),
                run(1, older, "2026-11-20T18", meta="success", chromium="cancelled", webkit="cancelled")]
        result = self.repo.sync(releases, runs)
        self.assertEqual(result["engines"], "chromium")
        self.assertEqual(reasons(result)["chromium"], (True, "upstream 0.50.2 -> 0.51.0 since v0.50.2-r1"))
        self.assertFalse(reasons(result)["webkit"][0])

    def test_webkit_missing_at_head(self):
        self.repo.tag("v0.51.0-r1")
        result = self.repo.sync([release("v0.51.0-r1", "2026-11-20T01")])
        self.assertEqual(result["engines"], "webkit")
        self.assertEqual(reasons(result)["webkit"], (True, "no release yet"))

    def test_failed_flavor_at_head_is_not_retried(self):
        self.repo.tag("v0.50.2-r1")
        self.repo.tag("v0.50.2-r1-webkit")
        head = self.repo.commit("Sources/Other.swift", "fork")
        self.repo.tag("v0.50.2-r2-webkit")
        releases = [release("v0.50.2-r1", "2026-11-20T01"), release("v0.50.2-r1-webkit", "2026-11-20T02"),
                    release("v0.50.2-r2-webkit", "2026-11-20T03")]
        for conclusion in ("failure", "cancelled", "timed_out"):
            with self.subTest(conclusion=conclusion):
                runs = [run(3, head, "2026-11-20T03", meta="success", chromium=conclusion, webkit="success")]
                result = self.repo.sync(releases, runs, upstream="0.50.2")
                self.assertEqual(result["engines"], "none")
                self.assertIn(f"build chromium ended {conclusion}", reasons(result)["chromium"][1])

    def test_later_run_without_the_flavor_keeps_it_blocked(self):
        self.repo.tag("v0.50.2-r1")
        head = self.repo.commit("Sources/Other.swift", "fork")
        self.repo.tag("v0.50.2-r1-webkit")
        runs = [run(4, head, "2026-11-20T04", meta="success", webkit="success"),
                run(3, head, "2026-11-20T03", meta="success", chromium="failure", webkit="failure")]
        result = self.repo.sync([release("v0.50.2-r1", "2026-11-20T01"), release("v0.50.2-r1-webkit", "2026-11-20T04")],
                                runs, upstream="0.50.2")
        self.assertEqual(result["engines"], "none")

    def test_failed_version_step_blocks_both(self):
        runs = [run(5, self.repo.head(), "2026-11-20T05", meta="failure")]
        self.assertEqual(self.repo.sync([], runs)["engines"], "none")

    def test_failure_at_an_older_commit_does_not_block(self):
        older = self.repo.head()
        self.repo.commit("Sources/Other.swift", "fork")
        runs = [run(6, older, "2026-11-20T06", meta="success", chromium="failure", webkit="failure")]
        self.assertEqual(self.repo.sync([], runs)["engines"], "all")


class RevisionTests(unittest.TestCase):
    def test_first_release_of_a_version(self):
        self.assertEqual(plan.plan_revision({"v0.50.2-r1": "a"}, "0.51.0", "all", "b"), "0.51.0-r1")

    def test_new_run_takes_the_next_r_of_either_flavor(self):
        refs = {"v0.51.0-r1": "a", "v0.51.0-r1-webkit": "a", "v0.51.0-r2-webkit": "b"}
        self.assertEqual(plan.plan_revision(refs, "0.51.0", "all", "c"), "0.51.0-r3")
        self.assertEqual(plan.plan_revision(refs, "0.51.0", "webkit", "c"), "0.51.0-r3")

    def test_fills_in_the_missing_flavor_of_the_same_commit(self):
        self.assertEqual(plan.plan_revision({"v0.51.0-r1-webkit": "e823"}, "0.51.0", "chromium", "e823"), "0.51.0-r1")
        self.assertEqual(plan.plan_revision({"v0.51.0-r1": "e823"}, "0.51.0", "webkit", "e823"), "0.51.0-r1")

    def test_other_commit_or_unknown_commit_takes_the_next_r(self):
        self.assertEqual(plan.plan_revision({"v0.51.0-r1-webkit": "e823"}, "0.51.0", "chromium", "7964"), "0.51.0-r2")
        self.assertEqual(plan.plan_revision({"v0.51.0-r1-webkit": None}, "0.51.0", "chromium", "e823"), "0.51.0-r2")

    def test_building_both_never_reuses(self):
        self.assertEqual(plan.plan_revision({"v0.51.0-r1-webkit": "e823"}, "0.51.0", "all", "e823"), "0.51.0-r2")

    def test_only_the_newest_r_is_filled(self):
        refs = {"v0.51.0-r1-webkit": "e823", "v0.51.0-r2": "f00", "v0.51.0-r2-webkit": "f00"}
        self.assertEqual(plan.plan_revision(refs, "0.51.0", "chromium", "e823"), "0.51.0-r3")

    def test_other_versions_and_odd_tags_are_ignored(self):
        refs = {"v0.51.0-r9x": "a", "v0.51.01-r4": "a", "v0.5-r7": "a", "v0.51.0-r1": "a"}
        self.assertEqual(plan.plan_revision(refs, "0.51.0", "all", "b"), "0.51.0-r2")

    def test_unknown_engines_fail(self):
        with self.assertRaises(plan.PlanError):
            plan.plan_revision({}, "0.51.0", "gecko", "a")

    def test_cli_reads_matching_refs_and_skips_annotated_tags(self):
        refs = [{"ref": "refs/tags/v0.51.0-r1-webkit", "object": {"sha": "e823", "type": "commit"}},
                {"ref": "refs/tags/v0.51.0-r2-webkit", "object": {"sha": "e823", "type": "tag"}}]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(refs, f)
        self.addCleanup(os.unlink, f.name)
        out = subprocess.run([sys.executable, "-I", str(SCRIPT), "revision", "--refs", f.name, "--upstream", "0.51.0",
                              "--engines", "chromium", "--sha", "e823"], check=True, capture_output=True, text=True)
        self.assertEqual(out.stdout.strip(), "0.51.0-r3")


if __name__ == "__main__":
    unittest.main()
