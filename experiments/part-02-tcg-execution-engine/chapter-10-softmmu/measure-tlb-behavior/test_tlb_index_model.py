#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tests that make the model's scope and replacement rule explicit."""

import unittest

from tlb_index_model import (
    DirectMappedTLB,
    conflicting_pages,
    same_page,
    sequential_pages,
)


class DirectMappedTLBTests(unittest.TestCase):
    def test_same_page_misses_once(self) -> None:
        counts = DirectMappedTLB().replay(same_page(1024))
        self.assertEqual((counts.hits, counts.misses), (1023, 1))

    def test_small_sequential_working_set_warms_up(self) -> None:
        counts = DirectMappedTLB().replay(sequential_pages(64, 4))
        self.assertEqual((counts.hits, counts.misses), (192, 64))

    def test_pages_one_table_apart_conflict(self) -> None:
        counts = DirectMappedTLB().replay(conflicting_pages(256, 100))
        self.assertEqual((counts.hits, counts.misses), (0, 100))

    def test_non_power_of_two_table_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            DirectMappedTLB(entries=255)


if __name__ == "__main__":
    unittest.main()
