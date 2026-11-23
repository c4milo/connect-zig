"""Tests of the helpers of tools/fullstack/servers.sh that run alone: rotate, word_at, udp_port_held,
and load_ticks (tools/scripts_test.sh). Each test sources the file in sh, with `work` a folder of
its own, since sourcing it writes the servers' configurations there."""

import os
import pathlib
import socket
import subprocess
import tempfile
import unittest

root = pathlib.Path(__file__).resolve().parents[2]
# Fields 2 to 9 of a line of /proc/stat: user, nice, system, idle, iowait, irq, softirq, and steal;
# then guest and guest_nice, which user and nice already hold.
stat_lines = [
    "cpu  11 22 33 44 55 66 77 88 99 110",
    "cpu0 1 2 3 4 5 6 7 8 9 10",
    "cpu1 10 20 30 40 50 60 70 80 90 100",
    "cpu2 100 200 300 400 500 600 700 800 900 1000",
    "intr 12345",
]


def sh(script, **variables):
    """Runs the script in sh after servers.sh, and returns its exit status and its output."""
    with tempfile.TemporaryDirectory() as work:
        environment = dict(os.environ, work=work, **variables)
        done = subprocess.run(
            ["sh", "-c", f". tools/fullstack/servers.sh\n{script}"],
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
    return done.returncode, done.stdout.strip()


class WordsTest(unittest.TestCase):
    def test_rotate_moves_the_first_words_to_the_end(self):
        self.assertEqual(sh("rotate 1 a b c"), (0, "b c a"))
        self.assertEqual(sh("rotate 0 a b c"), (0, "a b c"))
        self.assertEqual(sh("rotate 2 a b c"), (0, "c a b"))
        # The count wraps around the words.
        self.assertEqual(sh("rotate 4 a b c"), (0, "b c a"))

    def test_word_at_counts_from_0(self):
        self.assertEqual(sh("word_at 0 a b c"), (0, "a"))
        self.assertEqual(sh("word_at 2 a b c"), (0, "c"))


@unittest.skipUnless(pathlib.Path("/proc/net/udp").exists(), "needs Linux's /proc/net/udp")
class UdpPortTest(unittest.TestCase):
    def test_a_bound_port_is_held_until_its_socket_closes(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as bound:
            bound.bind(("127.0.0.1", 0))
            port = bound.getsockname()[1]
            self.assertEqual(sh(f"udp_port_held {port}")[0], 0)
        self.assertEqual(sh(f"udp_port_held {port}")[0], 1)

    @unittest.skipUnless(pathlib.Path("/proc/net/udp6").exists(), "needs IPv6")
    def test_a_port_of_ipv6_is_held_too(self):
        with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as bound:
            bound.bind(("::1", 0))
            port = bound.getsockname()[1]
            self.assertEqual(sh(f"udp_port_held {port}")[0], 0)


class LoadTicksTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.stat = os.path.join(self.folder.name, "stat")
        pathlib.Path(self.stat).write_text("\n".join(stat_lines) + "\n")

    def tearDown(self):
        self.folder.cleanup()

    def ticks(self, cores):
        return sh(f'proc_stat="{self.stat}"\nload_cores="{cores}"\nload_ticks')

    def test_no_core_pinned_gives_a_dash(self):
        self.assertEqual(self.ticks(""), (0, "-"))

    def test_counts_every_field_but_idle_and_iowait_as_busy(self):
        # cpu1: 360 ticks in its 8 fields, of which idle and iowait hold 90.
        self.assertEqual(self.ticks("1"), (0, "270:360"))

    def test_sums_the_load_cores_alone(self):
        # cpu0 and cpu2 alone: 27 of 36, and 2,700 of 3,600.
        self.assertEqual(self.ticks("0,2"), (0, "2727:3636"))


if __name__ == "__main__":
    unittest.main()
