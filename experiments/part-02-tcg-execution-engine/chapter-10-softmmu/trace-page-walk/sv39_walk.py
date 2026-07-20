#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Minimal one-stage Sv39 walk using Svade-style ADUE=0 fault semantics."""

from __future__ import annotations

from dataclasses import dataclass

PAGE_BITS = 12
PTE_V = 1 << 0
PTE_R = 1 << 1
PTE_W = 1 << 2
PTE_X = 1 << 3
PTE_U = 1 << 4
PTE_A = 1 << 6
PTE_D = 1 << 7


class PageFault(Exception):
    pass


@dataclass(frozen=True)
class WalkResult:
    physical_address: int
    leaf_level: int
    pte_address: int


def make_pte(ppn: int, flags: int) -> int:
    return (ppn << 10) | flags


def walk_sv39(
    virtual_address: int,
    root_ppn: int,
    memory: dict[int, int],
    access: str = "read",
    privilege: str = "S",
    sum_enabled: bool = False,
    mxr_enabled: bool = False,
) -> WalkResult:
    if access not in {"read", "write", "execute"}:
        raise ValueError("access must be read, write, or execute")
    vpn = [(virtual_address >> (12 + 9 * level)) & 0x1FF for level in range(3)]
    table_ppn = root_ppn

    for level in (2, 1, 0):
        pte_address = (table_ppn << PAGE_BITS) + vpn[level] * 8
        pte = memory.get(pte_address, 0)
        valid = bool(pte & PTE_V)
        readable = bool(pte & PTE_R)
        writable = bool(pte & PTE_W)
        executable = bool(pte & PTE_X)
        if not valid or (writable and not readable):
            raise PageFault("invalid PTE encoding")

        if readable or executable:
            user = bool(pte & PTE_U)
            if privilege == "U" and not user:
                raise PageFault("U-mode access to supervisor page")
            if privilege == "S" and user and (access == "execute" or not sum_enabled):
                raise PageFault("S-mode access to user page is blocked")
            if access == "read" and not (readable or (mxr_enabled and executable)):
                raise PageFault("read permission denied")
            if access == "write" and not writable:
                raise PageFault("write permission denied")
            if access == "execute" and not executable:
                raise PageFault("execute permission denied")
            if not (pte & PTE_A) or (access == "write" and not (pte & PTE_D)):
                raise PageFault("missing A/D faults in this ADUE=0 model")

            pte_ppn = pte >> 10
            low_bits = level * 9
            low_mask = (1 << low_bits) - 1 if low_bits else 0
            if pte_ppn & low_mask:
                raise PageFault("misaligned superpage")
            vpn_low = (virtual_address >> PAGE_BITS) & low_mask
            physical_ppn = (pte_ppn & ~low_mask) | vpn_low
            physical = (physical_ppn << PAGE_BITS) | (virtual_address & 0xFFF)
            return WalkResult(physical, level, pte_address)

        table_ppn = pte >> 10

    raise PageFault("walk reached no leaf")
