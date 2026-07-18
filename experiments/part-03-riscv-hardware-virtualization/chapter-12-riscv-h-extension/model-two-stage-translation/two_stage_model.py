#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Minimal responsibility model for RISC-V VS-stage plus G-stage."""

from __future__ import annotations

from dataclasses import dataclass


PAGE_SHIFT = 12
PAGE_SIZE = 1 << PAGE_SHIFT


@dataclass(frozen=True)
class Mapping:
    output_page: int
    read: bool = True
    write: bool = True
    execute: bool = True


@dataclass(frozen=True)
class Translation:
    host_physical_address: int
    read: bool
    write: bool
    execute: bool


class VsPageFault(Exception):
    pass


class GuestPageFault(Exception):
    def __init__(self, guest_physical_address: int, indirect: bool) -> None:
        self.guest_physical_address = guest_physical_address
        self.indirect = indirect
        super().__init__(
            f"guest-page-fault gpa=0x{guest_physical_address:x} indirect={indirect}"
        )


def _translate_g_stage(
    guest_physical_address: int,
    g_stage: dict[int, Mapping],
    *,
    indirect: bool,
) -> tuple[int, Mapping]:
    guest_page = guest_physical_address >> PAGE_SHIFT
    mapping = g_stage.get(guest_page)
    if mapping is None:
        raise GuestPageFault(guest_physical_address, indirect)
    offset = guest_physical_address & (PAGE_SIZE - 1)
    return (mapping.output_page << PAGE_SHIFT) | offset, mapping


def translate(
    guest_virtual_address: int,
    vs_stage: dict[int, Mapping],
    g_stage: dict[int, Mapping],
    *,
    vs_pte_guest_page: int,
) -> Translation:
    """Translate one address while exposing the indirect G-stage access.

    Real Sv39/Sv48 page walks are replaced with mappings. The model preserves
    the ownership and fault distinction that the experiment is meant to test.
    """

    _translate_g_stage(
        vs_pte_guest_page << PAGE_SHIFT,
        g_stage,
        indirect=True,
    )

    guest_virtual_page = guest_virtual_address >> PAGE_SHIFT
    vs_mapping = vs_stage.get(guest_virtual_page)
    if vs_mapping is None:
        raise VsPageFault(f"VS-stage has no mapping for GVA 0x{guest_virtual_address:x}")

    offset = guest_virtual_address & (PAGE_SIZE - 1)
    guest_physical_address = (vs_mapping.output_page << PAGE_SHIFT) | offset
    host_physical_address, g_mapping = _translate_g_stage(
        guest_physical_address,
        g_stage,
        indirect=False,
    )
    return Translation(
        host_physical_address=host_physical_address,
        read=vs_mapping.read and g_mapping.read,
        write=vs_mapping.write and g_mapping.write,
        execute=vs_mapping.execute and g_mapping.execute,
    )
