#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from two_stage_model import GuestPageFault, Mapping, VsPageFault, translate


GVA = 0x4000_0123
GVA_PAGE = GVA >> 12
GPA_PAGE = 0x80000
PTE_GUEST_PAGE = 0x70000
HPA_PAGE = 0x120000


class TwoStageModelTests(unittest.TestCase):
    def test_success_and_permission_intersection(self) -> None:
        result = translate(
            GVA,
            {GVA_PAGE: Mapping(GPA_PAGE, write=True)},
            {
                PTE_GUEST_PAGE: Mapping(0x110000),
                GPA_PAGE: Mapping(HPA_PAGE, write=False),
            },
            vs_pte_guest_page=PTE_GUEST_PAGE,
        )
        self.assertEqual(result.host_physical_address, (HPA_PAGE << 12) | 0x123)
        self.assertTrue(result.read)
        self.assertFalse(result.write)

    def test_missing_vs_leaf_is_vs_page_fault(self) -> None:
        with self.assertRaises(VsPageFault):
            translate(
                GVA,
                {},
                {PTE_GUEST_PAGE: Mapping(0x110000)},
                vs_pte_guest_page=PTE_GUEST_PAGE,
            )

    def test_missing_pte_backing_is_indirect_guest_page_fault(self) -> None:
        with self.assertRaises(GuestPageFault) as context:
            translate(
                GVA,
                {GVA_PAGE: Mapping(GPA_PAGE)},
                {GPA_PAGE: Mapping(HPA_PAGE)},
                vs_pte_guest_page=PTE_GUEST_PAGE,
            )
        self.assertTrue(context.exception.indirect)

    def test_missing_leaf_gpa_is_direct_guest_page_fault(self) -> None:
        with self.assertRaises(GuestPageFault) as context:
            translate(
                GVA,
                {GVA_PAGE: Mapping(GPA_PAGE)},
                {PTE_GUEST_PAGE: Mapping(0x110000)},
                vs_pte_guest_page=PTE_GUEST_PAGE,
            )
        self.assertFalse(context.exception.indirect)


if __name__ == "__main__":
    unittest.main()
