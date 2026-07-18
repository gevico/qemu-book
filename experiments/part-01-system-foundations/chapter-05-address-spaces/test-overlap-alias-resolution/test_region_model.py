#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from region_model import Region, resolve


class RegionModelTests(unittest.TestCase):
    def test_higher_priority_wins_overlap(self) -> None:
        regions = [
            Region("low", 0, 0x100, 0, 0),
            Region("high", 0x40, 0x100, 2, 1),
        ]
        self.assertEqual(resolve(regions, 0x80), ("high", 0x40))

    def test_later_equal_priority_region_is_ahead(self) -> None:
        regions = [Region("first", 0, 16, 0, 0), Region("later", 0, 16, 0, 1)]
        self.assertEqual(resolve(regions, 4), ("later", 4))

    def test_disabled_region_does_not_dispatch(self) -> None:
        regions = [
            Region("disabled", 0, 16, 5, 1, enabled=False),
            Region("fallback", 0, 16, 0, 0),
        ]
        self.assertEqual(resolve(regions, 2), ("fallback", 2))

    def test_alias_translates_offset(self) -> None:
        region = Region("alias", 0x2000, 0x100, 0, 0, alias_offset=0x80)
        self.assertEqual(resolve([region], 0x2010), ("alias", 0x90))


if __name__ == "__main__":
    unittest.main()
