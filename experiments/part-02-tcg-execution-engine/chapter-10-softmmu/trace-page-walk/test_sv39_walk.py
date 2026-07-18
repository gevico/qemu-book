#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from sv39_walk import (
    PTE_A,
    PTE_D,
    PTE_R,
    PTE_V,
    PTE_W,
    PageFault,
    make_pte,
    walk_sv39,
)


def four_kib_mapping(virtual: int, physical_ppn: int) -> tuple[int, dict[int, int]]:
    root_ppn, level1_ppn, level0_ppn = 1, 2, 3
    vpn = [(virtual >> (12 + 9 * level)) & 0x1FF for level in range(3)]
    memory = {
        (root_ppn << 12) + vpn[2] * 8: make_pte(level1_ppn, PTE_V),
        (level1_ppn << 12) + vpn[1] * 8: make_pte(level0_ppn, PTE_V),
        (level0_ppn << 12) + vpn[0] * 8: make_pte(
            physical_ppn, PTE_V | PTE_R | PTE_W | PTE_A | PTE_D
        ),
    }
    return root_ppn, memory


class Sv39WalkTests(unittest.TestCase):
    def test_three_level_read_translation(self) -> None:
        virtual = 0x0000000123456789
        root, memory = four_kib_mapping(virtual, 0x80000)
        result = walk_sv39(virtual, root, memory)
        self.assertEqual(result.physical_address, 0x80000789)
        self.assertEqual(result.leaf_level, 0)

    def test_write_requires_dirty(self) -> None:
        virtual = 0x4000
        root, memory = four_kib_mapping(virtual, 0x90000)
        leaf_address = (3 << 12) + ((virtual >> 12) & 0x1FF) * 8
        memory[leaf_address] &= ~PTE_D
        with self.assertRaises(PageFault):
            walk_sv39(virtual, root, memory, access="write")

    def test_write_without_read_is_invalid_encoding(self) -> None:
        virtual = 0x8000
        root, memory = four_kib_mapping(virtual, 0xA0000)
        leaf_address = (3 << 12) + ((virtual >> 12) & 0x1FF) * 8
        memory[leaf_address] = make_pte(0xA0000, PTE_V | PTE_W | PTE_A | PTE_D)
        with self.assertRaises(PageFault):
            walk_sv39(virtual, root, memory)


if __name__ == "__main__":
    unittest.main()
