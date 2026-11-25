"""Tests of tools/charts_previous.sh (tools/scripts_test.sh): the tag before a tag is the newest
v* tag its parent reaches, and the first tag has none."""

import os
import pathlib
import subprocess
import tempfile
import unittest

script = pathlib.Path(__file__).resolve().parent / "charts_previous.sh"


def git(arguments, cwd):
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    command = ["git", "-c", "user.name=t", "-c", "user.email=t@t", *arguments]
    return subprocess.run(command, cwd=cwd, env=environment, capture_output=True, text=True, check=True).stdout


def history(work):
    """A repository of four commits: v0.1.0, a tag that is no release, v0.2.0, and v0.3.0."""
    git(["init", "-q"], work)
    for tag in ("v0.1.0", "nightly", "v0.2.0", "v0.3.0"):
        git(["commit", "-q", "--allow-empty", "-m", tag], work)
        git(["tag", "-a", tag, "-m", tag], work)


def previous_tag(work, tag):
    body = f'. "{script}"\nprevious_tag {tag}\n'
    return subprocess.run(["sh", "-c", body], cwd=work, capture_output=True, text=True, check=True).stdout.strip()


class PreviousTagTest(unittest.TestCase):
    def test_the_tag_before_each_tag(self):
        with tempfile.TemporaryDirectory() as work:
            history(work)
            self.assertEqual(previous_tag(work, "v0.3.0"), "v0.2.0")
            self.assertEqual(previous_tag(work, "v0.2.0"), "v0.1.0")
            self.assertEqual(previous_tag(work, "v0.1.0"), "")


if __name__ == "__main__":
    unittest.main()
