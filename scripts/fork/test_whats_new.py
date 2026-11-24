#!/usr/bin/env python3
"""whats-new.py against a fixture upstream feed, a fixture pull request list and a scratch git repo.

usage: python3 -I scripts/fork/test_whats_new.py
"""
import argparse
import contextlib
from html.parser import HTMLParser
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "whats-new.py"
FIXTURES = HERE / "fixtures" / "whats-new"
spec = importlib.util.spec_from_file_location("whats_new", SCRIPT)
wn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wn)

FEED = str(FIXTURES / "feed.xml")
PRS = json.loads((FIXTURES / "prs.json").read_text())
SITE = "https://example.github.io/yab"


class FakeSource:
    def __init__(self, pulls=(), tags=(), ancestors=None):
        self.pulls, self._tags = list(pulls), list(tags)
        self.ancestors = set(tags if ancestors is None else ancestors)

    def tags(self):
        return self._tags

    def is_ancestor(self, tag, head):
        return tag in self.ancestors

    def pulls_between(self, prev, head):
        return self.pulls


def opts(**kw):
    base = dict(version="0.52.0-r3", upstream="0.52.0", head="a" * 40, repo="Serubin/yab", site=SITE,
                date="2026-11-23", prev_tag="v0.50.2-r1", feed=FEED)
    return argparse.Namespace(**(base | kw))


def entry(**kw):
    source = FakeSource(kw.pop("pulls", PRS))
    with contextlib.redirect_stderr(io.StringIO()):
        return wn.build_entry(opts(**kw), source)


def cli(*args):
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True)


class Tags(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.found = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        self.found.append((tag, dict(attrs)))

    def has(self, tag, **attrs):
        return any(t == tag and all(a.get(k) == v for k, v in attrs.items()) for t, a in self.found)


class Notes(unittest.TestCase):
    def test_two_upstream_entries_and_the_kept_pull_requests_in_merge_order(self):
        e = entry()
        self.assertEqual([u["minor"] for u in e["upstream"]["entries"]], ["0.52", "0.51"])
        self.assertEqual([p["number"] for p in e["prs"]], [101, 102, 106])
        newest = e["upstream"]["entries"][0]
        self.assertEqual(newest["counts"], [{"name": "added", "count": 2}, {"name": "fixed", "count": 3}])
        self.assertEqual(newest["link"], "https://yetanotherbrowser.com/changelog/0.52")
        text = wn.render_markdown(e)
        self.assertIn("2 added, 3 fixed", text)
        self.assertIn("[Read Yab 0.52 notes](https://yetanotherbrowser.com/changelog/0.52)", text)
        self.assertIn("Based on Yab, by Serafim Korablev.", text)
        self.assertLess(text.index("Pane changes"), text.index("Keep a tab"))
        self.assertLess(text.index("Keep a tab"), text.index("Normalize"))

    def test_the_summary_comes_only_from_what_changes(self):
        by = {p["number"]: p["summary"] for p in entry()["prs"]}
        self.assertEqual(by[101], "A tab now keeps its scroll position across a reload, as Safari does.")
        self.assertIsNone(by[102])
        self.assertEqual(by[106], "Handles <b>markup</b> and thanks @octocat for the link.")

    def test_summary_is_capped_on_a_word_boundary(self):
        long = "## What changes\n\n" + " ".join(["word"] * 100) + "."
        text = wn.summary(long)
        self.assertLessEqual(len(text), wn.SUMMARY_MAX)
        self.assertTrue(text.endswith("word..."))

    def test_no_fork_pull_requests_leaves_the_section_out(self):
        e = entry(pulls=[PRS[2], PRS[3], PRS[4]])
        self.assertEqual(e["prs"], [])
        self.assertNotIn("Pane changes", wn.render_markdown(e))
        self.assertNotIn("Pane changes", wn.render_page([e], SITE, "Serubin/yab"))

    def test_missing_upstream_entry_falls_back_to_a_line_and_a_warning(self):
        result = cli("notes", "--version", "0.53.0-r1", "--upstream", "0.53.0", "--head", "a" * 40,
                     "--repo", "Serubin/yab", "--site", SITE, "--date", "2026-11-23", "--prev-tag", "v0.52.0-r2",
                     "--feed", FEED, "--prs", str(FIXTURES / "prs.json"), "--out", self.out())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning::", result.stderr)
        text = Path(self.out(), "notes.md").read_text()
        self.assertIn("Based on upstream Yab 0.53.0, by Serafim Korablev. Its notes: "
                      "[yetanotherbrowser.com/changelog](https://yetanotherbrowser.com/changelog).", text)
        self.assertNotIn("Read Yab", text)
        self.assertTrue(json.loads(Path(self.out(), "entry.json").read_text())["upstream"]["missing"])

    def test_unreachable_feed_is_the_same_fallback(self):
        e = entry(feed=str(FIXTURES / "no-such-feed.xml"))
        self.assertTrue(e["upstream"]["missing"])
        self.assertEqual(e["upstream"]["entries"], [])
        self.assertIn("Its notes:", wn.render_markdown(e))
        self.assertEqual(len(e["prs"]), 3)

    def test_same_upstream_as_the_previous_tag_says_unchanged(self):
        e = entry(prev_tag="v0.52.0-r2")
        self.assertEqual(e["upstream"]["unchanged_since"], "v0.52.0-r2")
        self.assertEqual([u["minor"] for u in e["upstream"]["entries"]], ["0.52"])
        self.assertIn("Upstream Yab 0.52.0, unchanged since Pane 0.52.0-r2.", wn.render_markdown(e))

    def test_a_newer_build_of_the_same_minor_shows_that_minors_entry(self):
        e = entry(upstream="0.52.1", prev_tag="v0.52.0-r2")
        self.assertIsNone(e["upstream"]["unchanged_since"])
        self.assertEqual([u["minor"] for u in e["upstream"]["entries"]], ["0.52"])

    def test_a_prerelease_version_gets_notes_too(self):
        e = entry(version="0.52.0-dev.202611231200", prev_tag="v0.52.0-r2")
        self.assertEqual(e["tag"], "v0.52.0-dev.202611231200")
        self.assertIn("Upstream Yab", wn.render_markdown(e))

    def test_the_first_release_shows_only_the_current_upstream_entry(self):
        e = entry(prev_tag=None)
        self.assertEqual([u["minor"] for u in e["upstream"]["entries"]], ["0.52"])
        self.assertIsNone(e["prev_tag"])
        self.assertEqual(e["prs"], [])

    def test_filtering(self):
        numbers = [p["number"] for p in wn.fork_prs(PRS, "Serubin/yab")]
        self.assertEqual(numbers, [101, 102, 106])
        for number in (103, 104, 105, 107, 108):
            self.assertNotIn(number, numbers)
        self.assertEqual({e["minor"] for e in entry()["upstream"]["entries"]}, {"0.52", "0.51"})
        self.assertFalse(any("iPhone" in e["title"] for e in wn.upstream_entries(Path(FEED).read_text())))

    def test_untrusted_text_is_escaped_and_foreign_urls_are_dropped(self):
        e = entry()
        text, page = wn.render_markdown(e), wn.render_page([e], SITE, "Serubin/yab")
        self.assertNotIn("<script>", page)
        self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", page)
        self.assertIn("@&#8203;octocat", text)
        self.assertIsNone(re.search(r"@\w", text))
        self.assertIn("\\<script\\>", text)
        self.assertNotIn("evil.example", text + page)
        hostile = json.loads(json.dumps(e))
        hostile["prs"][0]["url"] = "http://evil.example/pull/1"
        hostile["upstream"]["entries"][0]["link"] = "https://evil.example/changelog/0.52"
        for rendered in (wn.render_markdown(hostile), wn.render_page([hostile], SITE, "Serubin/yab")):
            self.assertNotIn("evil.example", rendered)

    def test_another_repos_pull_request_url_is_dropped(self):
        e = entry()
        e["prs"][0]["url"] = "https://github.com/someone/else/pull/101"
        for rendered in (wn.render_markdown(e), wn.render_page([e], SITE, "Serubin/yab")):
            self.assertNotIn("someone/else", rendered)
        self.assertIn("https://github.com/Serubin/yab/pull/102", wn.render_markdown(entry()))

    def test_bare_urls_in_titles_and_summaries_are_not_autolinked(self):
        pulls = [dict(PRS[0], number=201, title="fix: see https://evil.example/x and www.evil.example",
                      body="## What changes\n\nMirrors http://evil.example/y for ftp://evil.example and a@evil.example.")]
        text = wn.render_markdown(entry(pulls=pulls))
        prose = re.sub(r"\]\([^)]*\)", "]", text)
        self.assertIsNone(re.search(r"(?i)\b(https?|ftp)://|\bwww\.|@\w", prose))
        self.assertIn("evil.example", text)

    def test_feed_links_outside_upstream_fall_back_to_its_changelog(self):
        feed = Path(FEED).read_text().replace("https://yetanotherbrowser.com/changelog/0.52<",
                                              "https://evil.example/0.52<", 1)
        self.assertEqual(wn.upstream_entries(feed)[0]["link"], "https://yetanotherbrowser.com/changelog")

    def test_a_pull_request_title_is_shown_as_is(self):
        self.assertEqual(entry()["prs"][0]["title"], "feat(tabs): Keep a tab's scroll position")

    def test_our_own_strings_have_no_em_dash(self):
        self.assertNotIn(chr(0x2014), SCRIPT.read_text())
        self.assertNotIn(chr(0x2014), Path(__file__).read_text())

    def out(self):
        if not hasattr(self, "_out"):
            tmp = tempfile.TemporaryDirectory()
            self.addCleanup(tmp.cleanup)
            self._out = tmp.name
        return self._out


class PreviousTag(unittest.TestCase):
    def test_skips_own_tags_and_orders_r10_above_r9(self):
        tags = ["v0.52.0-r3", "v0.52.0-r3-webkit", "v0.52.0-r9", "v0.52.0-r10-webkit", "v0.52.0-r10", "v0.51.0-r40",
                "v0.47.19-202611191115", "v0.52.0-dev.202611230032-webkit", "not-a-tag"]
        self.assertEqual(wn.previous_tag(FakeSource(tags=tags), "0.52.0-r11", "head"), "v0.52.0-r10")
        self.assertEqual(wn.previous_tag(FakeSource(tags=tags), "0.52.0-r10", "head"), "v0.52.0-r9")

    def test_a_dev_version_follows_the_newest_release(self):
        self.assertEqual(wn.previous_tag(FakeSource(tags=["v0.51.0-r2", "v0.52.0-r1"]), "0.52.0-dev.1", "h"),
                         "v0.52.0-r1")

    def test_none_when_there_is_no_earlier_release(self):
        self.assertIsNone(wn.previous_tag(FakeSource(tags=["v0.52.0-r1"]), "0.52.0-r1", "head"))
        self.assertIsNone(wn.previous_tag(FakeSource(), "0.52.0-r1", "head"))

    def test_against_a_scratch_git_repo(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env |= {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
                "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}

        def git(*args):
            return subprocess.run(["git", *args], cwd=tmp.name, env=env, check=True,
                                  capture_output=True, text=True).stdout.strip()

        def commit(name):
            Path(tmp.name, name).write_text(name)
            git("add", name)
            git("commit", "-q", "-m", name)
            return git("rev-parse", "HEAD")

        git("init", "-q", "-b", "canary")
        git("tag", "v0.51.0-r9", commit("one"))
        git("tag", "v0.51.0-r10", commit("two"))
        git("checkout", "-q", "-b", "side")
        git("tag", "v0.51.0-r11", commit("side"))
        git("checkout", "-q", "canary")
        head = commit("three")
        git("tag", "v0.52.0-r1", head)
        git("tag", "v0.52.0-r1-webkit", head)
        source = wn.Source("Serubin/yab", cwd=tmp.name)
        self.assertEqual(wn.previous_tag(source, "0.52.0-r1", head), "v0.51.0-r10")
        self.assertEqual(wn.previous_tag(source, "0.52.0-r2", head), "v0.52.0-r1")


class Page(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def write(self, name, value):
        path = self.dir / name
        path.write_text(value if isinstance(value, str) else json.dumps(value))
        return str(path)

    def page(self, e, live=None):
        args = ["page", "--entry", self.write("entry.json", e), "--site", SITE, "--out", str(self.dir / "out")]
        if live is not None:
            args += ["--live", self.write("live.json", live)]
        return cli(*args)

    def listed(self):
        return [x["version"] for x in json.loads((self.dir / "out" / "entries.json").read_text())]

    def test_merging_keeps_history_replaces_a_version_and_sorts_newest_first(self):
        r9, r10, r3 = entry(version="0.52.0-r9"), entry(version="0.52.0-r10"), entry(version="0.51.0-r3")
        self.assertEqual(self.page(r9).returncode, 0)
        self.assertEqual(self.listed(), ["0.52.0-r9"])
        live = json.loads((self.dir / "out" / "entries.json").read_text())
        self.assertEqual(self.page(r3, live).returncode, 0)
        self.assertEqual(self.listed(), ["0.52.0-r9", "0.51.0-r3"])
        live = json.loads((self.dir / "out" / "entries.json").read_text())
        self.assertEqual(self.page(r10, live).returncode, 0)
        self.assertEqual(self.listed(), ["0.52.0-r10", "0.52.0-r9", "0.51.0-r3"])
        live = json.loads((self.dir / "out" / "entries.json").read_text())
        again = entry(version="0.52.0-r10", date="2026-11-24")
        self.assertEqual(self.page(again, live).returncode, 0)
        self.assertEqual(self.listed(), ["0.52.0-r10", "0.52.0-r9", "0.51.0-r3"])
        self.assertIn("2026-11-24", (self.dir / "out" / "index.html").read_text())
        html = (self.dir / "out" / "index.html").read_text()
        self.assertLess(html.index('id="v0.52.0-r10"'), html.index('id="v0.52.0-r9"'))

    def test_a_malformed_live_copy_fails_and_writes_nothing(self):
        good = entry()
        for live in ({"not": "a list"}, [{"version": "0.52.0-r1"}], [dict(good, version="oops")], ["x"],
                     [dict(good, prs=[{"number": "1"}])]):
            result = self.page(good, live)
            self.assertNotEqual(result.returncode, 0, live)
            self.assertIn("bad entry", result.stderr)
            self.assertFalse((self.dir / "out").exists())
        self.assertNotEqual(cli("page", "--entry", self.write("bad.json", "{"), "--site", SITE,
                                "--out", str(self.dir / "out")).returncode, 0)

    def test_the_page_stands_on_its_own(self):
        text = wn.render_page([entry(), entry(version="0.52.0-r2", prev_tag=None)], SITE, "Serubin/yab")
        tags = Tags(text)
        self.assertTrue(tags.has("html", lang="en"))
        self.assertTrue(tags.has("meta", name="viewport", content="width=device-width, initial-scale=1"))
        self.assertTrue(tags.has("meta", **{"http-equiv": "Content-Security-Policy"}))
        self.assertIn("prefers-color-scheme: dark", text)
        self.assertIn("color-scheme: light dark", text)
        names = [t for t, _ in tags.found]
        self.assertNotIn("script", names)
        self.assertFalse(tags.has("link", rel="stylesheet"))
        self.assertIn("style", names)
        for tag, attrs in tags.found:
            self.assertNotIn("src", attrs, tag)
            for key, value in attrs.items():
                self.assertFalse((value or "").startswith("http:"), (tag, key))
                if key == "href" and tag != "link":
                    self.assertTrue(value.startswith(("https://", "#")), value)
        self.assertEqual(text.count("<article"), 2)
        self.assertNotIn(chr(0x2014), text)


if __name__ == "__main__":
    unittest.main()
