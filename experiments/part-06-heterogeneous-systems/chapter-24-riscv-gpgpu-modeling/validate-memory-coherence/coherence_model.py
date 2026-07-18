#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Small visibility model for a payload-plus-doorbell protocol."""

from __future__ import annotations

from itertools import permutations


PAYLOAD = "payload-visible"
DOORBELL = "doorbell-visible"


def device_observations(with_release_fence: bool) -> set[int]:
    """Return payload values permitted when the device observes a doorbell.

    The model distinguishes CPU program order from visibility order. It is an
    ABI oracle for the lab, not an implementation of RVWMO or a QEMU memory
    subsystem simulator.
    """

    observations: set[int] = set()
    for visibility_order in permutations((PAYLOAD, DOORBELL)):
        if with_release_fence and visibility_order.index(PAYLOAD) > visibility_order.index(
            DOORBELL
        ):
            continue

        visible_payload = 0
        for event in visibility_order:
            if event == PAYLOAD:
                visible_payload = 42
            elif event == DOORBELL:
                observations.add(visible_payload)
    return observations


def main() -> None:
    print("without-release-fence", sorted(device_observations(False)))
    print("with-release-fence", sorted(device_observations(True)))


if __name__ == "__main__":
    main()
