#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Executable register-level reference model for the teaching MMIO device."""

from __future__ import annotations

from dataclasses import dataclass, field


REG_ID = 0x00
REG_CONTROL = 0x04
REG_STATUS = 0x08
REG_DATA = 0x0C
REG_DOORBELL = 0x10

ID_VALUE = 0x51424D4D
CONTROL_ENABLE = 1 << 0
CONTROL_IRQ_ENABLE = 1 << 1
CONTROL_MASK = CONTROL_ENABLE | CONTROL_IRQ_ENABLE
STATUS_PENDING = 1 << 0
DATA_MASK = 0xFF


class AccessError(ValueError):
    """Raised when an access violates the 32-bit aligned MMIO contract."""


@dataclass
class RiscvMmioDevice:
    """Small state machine mirrored by the tree-out QEMU patch."""

    control: int = 0
    data: int = 0
    pending: bool = False
    _irq_output: bool = field(default=False, init=False, repr=False)

    @property
    def irq_level(self) -> bool:
        return self._irq_output

    def _update_irq(self) -> None:
        self._irq_output = self.pending and bool(
            self.control & CONTROL_IRQ_ENABLE
        )

    def reset_enter(self) -> None:
        """Clear only state owned by the device."""

        self.control = 0
        self.data = 0
        self.pending = False

    def reset_hold(self) -> None:
        """Propagate reset state to the externally owned IRQ line."""

        self._update_irq()

    def reset(self) -> None:
        self.reset_enter()
        self.reset_hold()

    @staticmethod
    def _check_access(offset: int, size: int) -> None:
        if size != 4:
            raise AccessError(f"only 32-bit accesses are valid, got {size} bytes")
        if offset < 0 or offset % 4:
            raise AccessError(f"offset must be non-negative and aligned: {offset:#x}")

    def read(self, offset: int, size: int = 4) -> int:
        self._check_access(offset, size)
        if offset == REG_ID:
            return ID_VALUE
        if offset == REG_CONTROL:
            return self.control
        if offset == REG_STATUS:
            return STATUS_PENDING if self.pending else 0
        if offset == REG_DATA:
            return self.data
        raise AccessError(f"register is not readable: {offset:#x}")

    def write(self, offset: int, value: int, size: int = 4) -> None:
        self._check_access(offset, size)
        value &= 0xFFFFFFFF
        if offset == REG_CONTROL:
            self.control = value & CONTROL_MASK
            self._update_irq()
            return
        if offset == REG_STATUS:
            if value & STATUS_PENDING:
                self.pending = False
            self._update_irq()
            return
        if offset == REG_DATA:
            self.data = value & DATA_MASK
            return
        if offset == REG_DOORBELL:
            if value & 1 and self.control & CONTROL_ENABLE:
                self.pending = True
            self._update_irq()
            return
        raise AccessError(f"register is not writable: {offset:#x}")
