#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Focused tests for the private BOOKADD encoding."""

import unittest

from toy_opcode import BOOKADD_MASK, encode_bookadd, is_bookadd


class ToyOpcodeTests(unittest.TestCase):
    def test_expected_smoke_encoding(self) -> None:
        word = encode_bookadd(rd=10, rs1=10, rs2=11)
        self.assertEqual(word, 0xAAB5050B)
        self.assertTrue(is_bookadd(word))

    def test_all_register_fields_remain_variable(self) -> None:
        self.assertTrue(is_bookadd(encode_bookadd(31, 0, 17)))

    def test_adjacent_funct7_is_rejected(self) -> None:
        word = encode_bookadd(10, 10, 11) ^ (1 << 25)
        self.assertFalse(is_bookadd(word))

    def test_reserved_bits_are_part_of_mask(self) -> None:
        self.assertEqual(BOOKADD_MASK, 0xFE00707F)

    def test_invalid_register_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            encode_bookadd(32, 0, 0)


if __name__ == "__main__":
    unittest.main()
