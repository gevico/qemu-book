#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Encode and recognize the private BOOKADD teaching instruction."""

from __future__ import annotations

CUSTOM_0 = 0x0B
BOOKADD_FUNCT3 = 0
BOOKADD_FUNCT7 = 0x55
BOOKADD_MASK = 0xFE00707F
BOOKADD_MATCH = 0xAA00000B


def encode_bookadd(rd: int, rs1: int, rs2: int) -> int:
    """Return the 32-bit BOOKADD encoding, validating all register fields."""
    for name, value in (("rd", rd), ("rs1", rs1), ("rs2", rs2)):
        if not 0 <= value < 32:
            raise ValueError(f"{name} must be in [0, 31]")

    return (
        (BOOKADD_FUNCT7 << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (BOOKADD_FUNCT3 << 12)
        | (rd << 7)
        | CUSTOM_0
    )


def is_bookadd(word: int) -> bool:
    """Recognize exactly the fixed funct7/funct3/custom-0 pattern."""
    return (word & BOOKADD_MASK) == BOOKADD_MATCH


if __name__ == "__main__":
    print(f"BOOKADD a0, a0, a1 = 0x{encode_bookadd(10, 10, 11):08x}")
