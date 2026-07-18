#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Check that the deliberately flawed review fixture is intact."""

from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent
FIXTURE = PROJECT_DIR / "fixtures/flawed-device.c"


def main() -> int:
    source = FIXTURE.read_text(encoding="utf-8")
    required_markers = {
        "guest-controlled allocation": "g_malloc(s->guest_length * 16)",
        "unchecked DMA result": "address_space_read(",
        "timer lifetime": "timer_mod(",
        "incomplete reset": "static void flawed_reset",
        "missing migration note": "omits unrealize, VMState",
    }
    missing = [name for name, marker in required_markers.items() if marker not in source]
    if missing:
        for name in missing:
            print(f"MISSING: {name}")
        return 1
    print(f"OK: {len(required_markers)} intentional review markers are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
