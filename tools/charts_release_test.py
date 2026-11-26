"""Tests of tools/charts_release.sh (tools/scripts_test.sh): every chart a run drew is attached to
the tag's release with its file of values, a tag with no release gets one first, two files of one
name or no chart at all attach nothing, the comparison replaces the notes' section of an earlier
run, and the branch `charts` holds the latest tag's charts alone. A stub `gh` on the path writes
each call it gets to a log."""

import os
import pathlib
import subprocess
import tempfile
import unittest

script = pathlib.Path(__file__).resolve().parent / "charts_release.sh"
root = script.parent.parent
heading = "## Benchmarks since the previous tag"
# The stub: `release view` succeeds when RELEASE_EXISTS is set and prints RELEASE_BODY, `release
# edit` keeps the notes it gets in NOTES_OUT, and each call joins the log.
stub = """#!/bin/sh
echo "$*" >>"${GH_LOG}"
case "$1 $2" in
    "release view") [ -n "${RELEASE_EXISTS:-}" ] && printf '%s\\n' "${RELEASE_BODY:-}" ;;
    "release edit") cp "$5" "${NOTES_OUT}" ;;
esac
"""


def release(work, files, exists):
    """Runs the script's functions over `files`, a chart's path under the run's folder to its
    text, and returns the finished process and the calls the stub logged."""
    work = pathlib.Path(work)
    for path, text in files.items():
        chart = work / "charts" / path
        chart.parent.mkdir(parents=True, exist_ok=True)
        chart.write_text(text)
    (work / "bin").mkdir()
    gh = work / "bin" / "gh"
    gh.write_text(stub)
    gh.chmod(0o755)
    log = work / "gh.log"
    environment = dict(os.environ, PATH=f"{work / 'bin'}:{os.environ['PATH']}", GH_LOG=str(log))
    if exists:
        environment["RELEASE_EXISTS"] = "1"
    body = f'. "{script}"\ncharts_gather "{work / "charts"}" "{work / "gathered"}" && charts_attach "{work / "gathered"}" v1.2.3\n'
    done = subprocess.run(["sh", "-c", body], env=environment, capture_output=True, text=True, check=False)
    calls = log.read_text().splitlines() if log.exists() else []
    return done, calls


class ChartsReleaseTest(unittest.TestCase):
    def test_attaches_every_chart_to_a_release_that_exists(self):
        with tempfile.TemporaryDirectory() as work:
            files = {
                "charts-fullstack-ARM64/fullstack-arm64.svg": "a",
                "charts-fullstack-ARM64/fullstack-arm64.json": "{}",
                "charts-bench-compare-X64/speed-vs-go.svg": "b",
                "charts-bench-compare-X64/bench-compare.log": "not attached",
            }
            done, calls = release(work, files, exists=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(len(calls), 2)
            self.assertTrue(calls[1].startswith("release upload v1.2.3 "))
            self.assertIn("fullstack-arm64.svg", calls[1])
            self.assertIn("speed-vs-go.svg", calls[1])
            self.assertIn("fullstack-arm64.json", calls[1])
            self.assertNotIn("bench-compare.log", calls[1])
            self.assertTrue(calls[1].endswith("--clobber"))

    def test_creates_the_release_a_tag_lacks(self):
        with tempfile.TemporaryDirectory() as work:
            done, calls = release(work, {"charts-x/speed-vs-go.svg": "b"}, exists=False)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(calls[1], "release create v1.2.3 --verify-tag --title v1.2.3 --generate-notes")
            self.assertTrue(calls[2].startswith("release upload v1.2.3 "))

    def test_two_charts_of_one_name_attach_nothing(self):
        with tempfile.TemporaryDirectory() as work:
            files = {"charts-a/speed-vs-go.svg": "a", "charts-b/speed-vs-go.svg": "b"}
            done, calls = release(work, files, exists=True)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("two charts are named speed-vs-go.svg", done.stderr)
            self.assertEqual(calls, [])

    def test_no_chart_attaches_nothing(self):
        with tempfile.TemporaryDirectory() as work:
            done, calls = release(work, {"charts-a/log.txt": "a"}, exists=True)
            self.assertNotEqual(done.returncode, 0)
            self.assertEqual(calls, [])


class NotesTest(unittest.TestCase):
    def test_replaces_the_section_of_an_earlier_run_and_keeps_the_rest(self):
        with tempfile.TemporaryDirectory() as work:
            work = pathlib.Path(work)
            (work / "bin").mkdir()
            gh = work / "bin" / "gh"
            gh.write_text(stub)
            gh.chmod(0o755)
            text = work / "compare.md"
            text.write_text(f"{heading}\n\nnew table\n")
            summary = work / "summary.md"
            environment = dict(
                os.environ,
                PATH=f"{work / 'bin'}:{os.environ['PATH']}",
                GH_LOG=str(work / "gh.log"),
                RELEASE_EXISTS="1",
                RELEASE_BODY=f"What changed\n\n{heading}\n\nold table",
                NOTES_OUT=str(work / "notes.md"),
                GITHUB_STEP_SUMMARY=str(summary),
            )
            body = f'. "{script}"\ncharts_notes "{text}" v1.2.3\n'
            subprocess.run(["sh", "-c", body], cwd=root, env=environment, capture_output=True, text=True, check=True)
            notes = (work / "notes.md").read_text()
            self.assertEqual(notes, f"What changed\n\n{heading}\n\nnew table\n")
            self.assertEqual(summary.read_text(), f"{heading}\n\nnew table\n")


def git(directory, *arguments):
    """Runs git in `directory` and returns what it printed, stripped."""
    done = subprocess.run(["git", "-C", str(directory), *arguments], capture_output=True, text=True, check=True)
    return done.stdout.strip()


def push_charts(checkout, folder, tag):
    """Runs the script's `charts_branch` over `folder` in `checkout`, for `tag`."""
    body = f'. "{script}"\ncharts_branch "{folder}" {tag}\n'
    subprocess.run(["sh", "-c", body], cwd=checkout, capture_output=True, text=True, check=True)


def checkout_with_remote(work):
    """A checkout with one commit, whose remote `origin` is a bare repository beside it."""
    remote, checkout = work / "remote.git", work / "checkout"
    git(work, "init", "-q", "--bare", str(remote))
    git(work, "init", "-q", "-b", "main", str(checkout))
    (checkout / "README.md").write_text("main\n")
    git(checkout, "add", "README.md")
    git(checkout, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "main")
    git(checkout, "remote", "add", "origin", str(remote))
    return remote, checkout


def charts_folder(work, name, files):
    """A folder of gathered charts, each file's name to its text."""
    folder = work / name
    folder.mkdir()
    for file, text in files.items():
        (folder / file).write_text(text)
    return folder


class BranchTest(unittest.TestCase):
    def test_the_branch_holds_the_latest_tags_charts_alone(self):
        with tempfile.TemporaryDirectory() as work:
            work = pathlib.Path(work)
            remote, checkout = checkout_with_remote(work)
            head = git(checkout, "rev-parse", "HEAD")
            push_charts(checkout, charts_folder(work, "first", {"a.svg": "1", "a.json": "{}", "b.svg": "2"}), "v1.0.0")
            push_charts(checkout, charts_folder(work, "second", {"a.svg": "3", "a.json": "{}"}), "v1.1.0")
            self.assertEqual(git(remote, "ls-tree", "--name-only", "charts").split(), ["a.json", "a.svg"])
            self.assertEqual(git(remote, "show", "charts:a.svg"), "3")
            self.assertEqual(git(remote, "rev-list", "--count", "charts"), "1")
            self.assertEqual(git(remote, "log", "-1", "--format=%s", "charts"), "chore: draw the charts of v1.1.0")
            self.assertEqual(git(checkout, "rev-parse", "HEAD"), head)
            self.assertEqual(git(checkout, "status", "--porcelain"), "")


if __name__ == "__main__":
    unittest.main()
