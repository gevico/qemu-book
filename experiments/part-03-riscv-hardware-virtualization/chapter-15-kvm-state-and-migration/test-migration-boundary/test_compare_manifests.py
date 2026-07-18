#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from compare_manifests import compare


def manifest() -> dict[str, object]:
    return {
        "architecture": "riscv64",
        "qemu_sha256": "abc",
        "machine": "virt",
        "cpu": "host",
        "accelerator": "kvm",
        "qemu_target": "v11.1.0",
        "dev_kvm_readable": True,
        "dev_kvm_writable": True,
        "kvm_listed": True,
    }


class ManifestComparisonTests(unittest.TestCase):
    def test_matching_manifest_has_no_mismatch(self) -> None:
        self.assertEqual(compare(manifest(), manifest()), [])

    def test_cpu_or_kvm_difference_is_reported(self) -> None:
        destination = manifest()
        destination["cpu"] = "rv64"
        destination["dev_kvm_writable"] = False
        self.assertEqual(
            compare(manifest(), destination),
            ["cpu", "destination_kvm_unavailable"],
        )


if __name__ == "__main__":
    unittest.main()
