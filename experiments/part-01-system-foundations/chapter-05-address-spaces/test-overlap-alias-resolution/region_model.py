#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Small executable model of overlap priority and alias offset dispatch."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Region:
    name: str
    start: int
    size: int
    priority: int
    insertion: int
    enabled: bool = True
    alias_offset: int | None = None

    def contains(self, address: int) -> bool:
        return self.enabled and self.start <= address < self.start + self.size

    def target_offset(self, address: int) -> int:
        local = address - self.start
        return local if self.alias_offset is None else self.alias_offset + local


def resolve(regions: list[Region], address: int) -> tuple[str, int] | None:
    candidates = [region for region in regions if region.contains(address)]
    if not candidates:
        return None
    winner = max(candidates, key=lambda region: (region.priority, region.insertion))
    return winner.name, winner.target_offset(address)


if __name__ == "__main__":
    topology = [
        Region("low", 0x1000, 0x100, priority=0, insertion=0),
        Region("high", 0x1080, 0x100, priority=10, insertion=1),
        Region("alias", 0x2000, 0x100, priority=0, insertion=2, alias_offset=0x80),
    ]
    for probe in (0x1040, 0x1088, 0x2010):
        print(f"0x{probe:x} -> {resolve(topology, probe)}")
