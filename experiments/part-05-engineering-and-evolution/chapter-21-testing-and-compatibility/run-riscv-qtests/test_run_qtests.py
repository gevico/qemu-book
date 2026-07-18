#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Regression tests for configured Meson test-name parsing."""

from __future__ import annotations

import unittest

from run_qtests import configured_test_names


class ConfiguredTestNameTests(unittest.TestCase):
    def test_suite_prefix_is_not_part_of_configured_name(self) -> None:
        output = (
            "qtest+qtest-riscv64 - "
            "qemu:qtest-riscv64/riscv-csr-test\n"
        )
        self.assertEqual(
            configured_test_names(output),
            ["qemu:qtest-riscv64/riscv-csr-test"],
        )

    def test_unprefixed_name_and_blank_lines_are_supported(self) -> None:
        self.assertEqual(
            configured_test_names("\nqemu:plain-test\n"),
            ["qemu:plain-test"],
        )


if __name__ == "__main__":
    unittest.main()
