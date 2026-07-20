#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from riscv_mmio_model import (
    AccessError,
    CONTROL_ENABLE,
    CONTROL_IRQ_ENABLE,
    CONTROL_MASK,
    DATA_MASK,
    ID_VALUE,
    REG_CONTROL,
    REG_DATA,
    REG_DOORBELL,
    REG_ID,
    REG_STATUS,
    STATUS_PENDING,
    RiscvMmioDevice,
)


class RiscvMmioDeviceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.device = RiscvMmioDevice()

    def test_reset_state_and_id(self) -> None:
        self.assertEqual(self.device.read(REG_ID), ID_VALUE)
        self.assertEqual(self.device.read(REG_CONTROL), 0)
        self.assertEqual(self.device.read(REG_STATUS), 0)
        self.assertEqual(self.device.read(REG_DATA), 0)
        self.assertFalse(self.device.irq_level)

    def test_writable_register_masks(self) -> None:
        self.device.write(REG_CONTROL, 0xFFFFFFFF)
        self.device.write(REG_DATA, 0xFFFFFFFF)
        self.assertEqual(self.device.read(REG_CONTROL), CONTROL_MASK)
        self.assertEqual(self.device.read(REG_DATA), DATA_MASK)

    def test_disabled_doorbell_has_no_effect(self) -> None:
        self.device.write(REG_DOORBELL, 1)
        self.assertEqual(self.device.read(REG_STATUS), 0)
        self.assertFalse(self.device.irq_level)

    def test_pending_and_irq_are_separate_state(self) -> None:
        self.device.write(REG_CONTROL, CONTROL_ENABLE)
        self.device.write(REG_DOORBELL, 1)
        self.assertEqual(self.device.read(REG_STATUS), STATUS_PENDING)
        self.assertFalse(self.device.irq_level)

        self.device.write(
            REG_CONTROL,
            CONTROL_ENABLE | CONTROL_IRQ_ENABLE,
        )
        self.assertTrue(self.device.irq_level)

    def test_status_is_write_one_to_clear(self) -> None:
        self.device.write(REG_CONTROL, CONTROL_ENABLE | CONTROL_IRQ_ENABLE)
        self.device.write(REG_DOORBELL, 1)
        self.device.write(REG_STATUS, 0)
        self.assertTrue(self.device.irq_level)

        self.device.write(REG_STATUS, STATUS_PENDING)
        self.assertEqual(self.device.read(REG_STATUS), 0)
        self.assertFalse(self.device.irq_level)

    def test_reset_enter_precedes_cross_object_irq_hold(self) -> None:
        self.device.write(REG_CONTROL, CONTROL_ENABLE | CONTROL_IRQ_ENABLE)
        self.device.write(REG_DATA, 0x5A)
        self.device.write(REG_DOORBELL, 1)
        self.assertTrue(self.device.irq_level)

        self.device.reset_enter()
        self.assertEqual(self.device.read(REG_CONTROL), 0)
        self.assertEqual(self.device.read(REG_DATA), 0)
        self.assertEqual(self.device.read(REG_STATUS), 0)
        self.assertTrue(self.device.irq_level)

        self.device.reset_hold()
        self.assertFalse(self.device.irq_level)

    def test_access_width_alignment_and_direction(self) -> None:
        with self.assertRaises(AccessError):
            self.device.read(REG_ID, size=2)
        with self.assertRaises(AccessError):
            self.device.write(REG_CONTROL + 1, 1)
        with self.assertRaises(AccessError):
            self.device.write(REG_ID, 1)
        with self.assertRaises(AccessError):
            self.device.read(REG_DOORBELL)


if __name__ == "__main__":
    unittest.main()
