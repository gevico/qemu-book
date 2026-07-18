#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Unit tests cover parsing and output safety without claiming live migration."""

import pathlib
import socket
import tempfile
import unittest

from migrate_smoke import RESULTS_MARKER, parse_counters, prepare_results_directory


class CounterParserTests(unittest.TestCase):
    def test_parses_only_complete_counter_lines(self) -> None:
        text = "boot\ncounter=0000000000400000\ncounter=0000000000800000\n"
        self.assertEqual(parse_counters(text), [0x400000, 0x800000])

    def test_rejects_truncated_or_non_hex_values(self) -> None:
        text = "counter=1234\ncounter=00000000000000zz\n"
        self.assertEqual(parse_counters(text), [])


class ResultsDirectorySafetyTests(unittest.TestCase):
    def test_nonempty_unmarked_directory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            results = pathlib.Path(temporary_directory)
            (results / "unrelated.txt").write_text("keep\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "non-empty unmarked"):
                prepare_results_directory(results)
            self.assertEqual(
                (results / "unrelated.txt").read_text(encoding="utf-8"),
                "keep\n",
            )

    def test_symlinked_log_is_rejected_without_touching_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            results = root / "results"
            results.mkdir()
            (results / RESULTS_MARKER).touch()
            target = root / "user-data.txt"
            target.write_text("keep\n", encoding="utf-8")
            (results / "source.stderr").symlink_to(target)
            with self.assertRaisesRegex(ValueError, "non-regular log path"):
                prepare_results_directory(results)
            self.assertEqual(target.read_text(encoding="utf-8"), "keep\n")

    def test_stale_unix_socket_is_removed_after_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            results = pathlib.Path(temporary_directory)
            (results / RESULTS_MARKER).touch()
            socket_path = results / "source.qmp"
            unix_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(unix_socket.close)
            unix_socket.bind(str(socket_path))
            prepare_results_directory(results)
            self.assertFalse(socket_path.exists())


if __name__ == "__main__":
    unittest.main()
