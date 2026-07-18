#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import json
import unittest
from pathlib import Path

from validate_platform import validate


PROJECT_DIR = Path(__file__).resolve().parent


class PlatformValidationTests(unittest.TestCase):
    def test_unknown_example_is_honest_and_complete(self) -> None:
        document = json.loads(
            (PROJECT_DIR / "platform.example.json").read_text(encoding="utf-8")
        )
        self.assertEqual(validate(document), [])

    def test_verified_claim_requires_evidence(self) -> None:
        document = json.loads(
            (PROJECT_DIR / "fixtures/invalid-verified.json").read_text(
                encoding="utf-8"
            )
        )
        errors = validate(document, require_minimum=False)
        self.assertIn("components[0] marked verified without evidence", errors)


if __name__ == "__main__":
    unittest.main()
