#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from coherence_model import device_observations


class CoherenceModelTests(unittest.TestCase):
    def test_unordered_visibility_keeps_stale_value_possible(self) -> None:
        self.assertEqual(device_observations(False), {0, 42})

    def test_release_fence_orders_payload_before_doorbell(self) -> None:
        self.assertEqual(device_observations(True), {42})


if __name__ == "__main__":
    unittest.main()
