#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Trace parser tests cover valid translations and fault records."""

import unittest

from analyze_iommu_trace import summarize


class IOMMUTraceTests(unittest.TestCase):
    def test_translation_is_grouped_by_direction_and_device(self) -> None:
        lines = [
            "1 riscv_iommu_dma iommu: translate 0000:00:02.0 #0 write "
            "0x1000 -> 0x80001000",
            "2 riscv_iommu_dma iommu: translate 0000:00:02.0 #0 read "
            "0x2000 -> 0x80002000",
        ]
        result = summarize(lines)
        self.assertEqual(result["translations"], 2)
        self.assertEqual(result["directions"], {"read": 1, "write": 1})

    def test_fault_is_not_counted_as_translation(self) -> None:
        lines = [
            "3 riscv_iommu_flt iommu: fault 0000:00:02.0 reason: 0x5 "
            "iova: 0xdead000"
        ]
        result = summarize(lines)
        self.assertEqual(result["translations"], 0)
        self.assertEqual(result["faults"], 1)
        self.assertEqual(result["fault_reasons"], {"5": 1})


if __name__ == "__main__":
    unittest.main()
