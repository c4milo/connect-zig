"""Tests of tools/charts_commit.sh (tools/scripts_test.sh): a tag's charts replace the charts of
docs/images by name, a chart the run did not draw keeps its file, no other chart joins, and a run
that changed nothing commits nothing. Each test runs the script's functions in a repository of its
own, which a push reaches through a bare repository beside it."""

import os
import pathlib
import subprocess
import tempfile
import unittest

script = pathlib.Path(__file__).resolve().parent / "charts_commit.sh"


def run(command, cwd):
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=True).stdout


def repository(work):
    """A clone of a bare repository whose main holds two charts, and the clone's path."""
    origin = pathlib.Path(work, "origin.git")
    clone = pathlib.Path(work, "clone")
    run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], work)
    run(["git", "init", "-q", "-b", "main", str(clone)], work)
    images = clone / "docs" / "images"
    images.mkdir(parents=True)
    (images / "speed.svg").write_text("old speed\n")
    (images / "fullstack.svg").write_text("old fullstack\n")
    for command in (
        ["git", "add", "docs"],
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "docs: add charts"],
        ["git", "remote", "add", "origin", str(origin)],
        ["git", "push", "-q", "origin", "main"],
    ):
        run(command, clone)
    return clone


def charts(work, files):
    """A folder of charts as `gh run download` writes them: one folder each artifact."""
    folder = pathlib.Path(work, "charts")
    for name, text in files.items():
        path = folder / "charts-check-X64" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return folder


def commit_charts(clone, folder, tag="v1.2.3"):
    """Runs the script's functions in `clone`, as its `main` runs them after its `cd`."""
    body = f'. "{script}"\ncharts_copy "{folder}"\ncharts_record {tag} || exit 0\ncharts_push\n'
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return subprocess.run(["sh", "-c", body], cwd=clone, env=environment, capture_output=True, text=True, check=True)


class ChartsCommitTest(unittest.TestCase):
    def test_replaces_charts_by_name_and_adds_none(self):
        with tempfile.TemporaryDirectory() as work:
            clone = repository(work)
            folder = charts(work, {"speed.svg": "new speed\n", "routes.svg": "new routes\n"})
            done = commit_charts(clone, folder)
            images = clone / "docs" / "images"
            self.assertEqual((images / "speed.svg").read_text(), "new speed\n")
            self.assertEqual((images / "fullstack.svg").read_text(), "old fullstack\n")
            self.assertFalse((images / "routes.svg").exists())
            self.assertIn("no fullstack.svg", done.stderr)
            pushed = run(["git", "log", "-1", "--format=%s %an", "main"], pathlib.Path(work, "origin.git"))
            self.assertEqual(pushed.strip(), "docs: draw the benchmark charts of v1.2.3 github-actions[bot]")

    def test_commits_nothing_when_no_chart_changed(self):
        with tempfile.TemporaryDirectory() as work:
            clone = repository(work)
            folder = charts(work, {"speed.svg": "old speed\n"})
            done = commit_charts(clone, folder)
            self.assertIn("no chart changed", done.stderr)
            count = run(["git", "rev-list", "--count", "main"], pathlib.Path(work, "origin.git"))
            self.assertEqual(count.strip(), "1")


if __name__ == "__main__":
    unittest.main()
