#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A transparent model of QEMU's direct-mapped SoftMMU fast-TLB index."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class Counts:
    accesses: int
    hits: int
    misses: int


class DirectMappedTLB:
    """Model only the fast-table page tag and replacement behavior."""

    def __init__(self, entries: int = 256, page_bits: int = 12) -> None:
        if entries <= 0 or entries & (entries - 1):
            raise ValueError("entries must be a positive power of two")
        self.entries = entries
        self.page_bits = page_bits
        self.tags: list[int | None] = [None] * entries

    def replay(self, addresses: Iterable[int]) -> Counts:
        accesses = hits = misses = 0
        for address in addresses:
            if address < 0:
                raise ValueError("addresses must be non-negative")
            page = address >> self.page_bits
            index = page & (self.entries - 1)
            accesses += 1
            if self.tags[index] == page:
                hits += 1
            else:
                misses += 1
                self.tags[index] = page
        return Counts(accesses, hits, misses)


def same_page(iterations: int, page_bits: int = 12) -> Iterable[int]:
    page_size = 1 << page_bits
    for item in range(iterations):
        yield (item * 8) & (page_size - 1)


def sequential_pages(pages: int, rounds: int, page_bits: int = 12) -> Iterable[int]:
    for _ in range(rounds):
        for page in range(pages):
            yield page << page_bits


def conflicting_pages(
    entries: int, iterations: int, page_bits: int = 12
) -> Iterable[int]:
    for item in range(iterations):
        page = entries if item & 1 else 0
        yield page << page_bits


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--entries", type=int, default=256)
    parser.add_argument("--iterations", type=int, default=4096)
    args = parser.parse_args()

    patterns = {
        "same-page": same_page(args.iterations),
        "sequential-64-pages": sequential_pages(64, args.iterations // 64),
        "single-index-conflict": conflicting_pages(args.entries, args.iterations),
    }

    print("pattern,accesses,hits,modeled_misses")
    for name, addresses in patterns.items():
        counts = DirectMappedTLB(entries=args.entries).replay(addresses)
        print(f"{name},{counts.accesses},{counts.hits},{counts.misses}")


if __name__ == "__main__":
    main()
