#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Tests for review-thread archive-anchor extraction."""

from __future__ import annotations

import unittest

from reconstruct import MESSAGE_ID, URL


class ArchiveAnchorTests(unittest.TestCase):
    def test_only_labeled_message_id_is_extracted(self) -> None:
        message = """\
Author: Developer <developer@example.com>
Reviewed-by: Reviewer <reviewer@example.com>
Message-ID: <patch.v3@example.com>
"""
        self.assertEqual(MESSAGE_ID.findall(message), ["<patch.v3@example.com>"])

    def test_archive_url_is_extracted(self) -> None:
        message = "Link: https://lore.kernel.org/qemu-devel/patch.v3@example.com/"
        self.assertEqual(
            URL.findall(message),
            ["https://lore.kernel.org/qemu-devel/patch.v3@example.com/"],
        )


if __name__ == "__main__":
    unittest.main()
