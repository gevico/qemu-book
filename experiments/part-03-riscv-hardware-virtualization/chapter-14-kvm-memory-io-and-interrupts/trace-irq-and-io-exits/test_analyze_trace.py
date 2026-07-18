#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Parser tests use synthetic lines and make no host-capability claim."""

import unittest

from analyze_trace import summarize


class TraceSummaryTests(unittest.TestCase):
    def test_counts_exit_reasons_and_serial_writes(self) -> None:
        lines = [
            "1@0 kvm_run_exit cpu_index 0, reason 6",
            "1@1 serial_write [0x00] <- 0x70",
            "1@2 kvm_run_exit cpu_index 0, reason 6",
            "1@3 kvm_run_exit cpu_index 0, reason 8",
        ]
        self.assertEqual(
            summarize(lines),
            {
                "kvm_run_exits": 3,
                "exit_reasons": {"6": 2, "8": 1},
                "serial_writes": 1,
            },
        )

    def test_empty_trace_is_not_fabricated(self) -> None:
        self.assertEqual(summarize([])["kvm_run_exits"], 0)


if __name__ == "__main__":
    unittest.main()
