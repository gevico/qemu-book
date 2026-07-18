#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Bounded reference model for the Chapter 24 toy command queue."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import Sequence


MAX_ELEMENTS = 1024


class Opcode(IntEnum):
    VECTOR_ADD = 1


class CompletionStatus(IntEnum):
    SUCCESS = 0
    INVALID_OPCODE = 1
    INVALID_LENGTH = 2
    QUEUE_FULL = 3
    RESET = 4


@dataclass(frozen=True)
class Descriptor:
    tag: int
    opcode: int
    left: Sequence[int]
    right: Sequence[int]
    element_count: int


@dataclass(frozen=True)
class Completion:
    tag: int
    status: CompletionStatus
    result: tuple[int, ...] = ()


class CommandQueue:
    """A fixed-depth queue with explicit validation and reset behavior."""

    def __init__(self, depth: int = 4) -> None:
        if depth < 1:
            raise ValueError("depth must be positive")
        self._depth = depth
        self._pending: list[Descriptor] = []
        self._completions: list[Completion] = []

    @property
    def pending_count(self) -> int:
        return len(self._pending)

    def submit(self, descriptor: Descriptor) -> CompletionStatus:
        if len(self._pending) >= self._depth:
            self._completions.append(
                Completion(descriptor.tag, CompletionStatus.QUEUE_FULL)
            )
            return CompletionStatus.QUEUE_FULL

        validation_error = self._validate(descriptor)
        if validation_error is not None:
            self._completions.append(Completion(descriptor.tag, validation_error))
            return validation_error

        # Copy the guest-owned sequences at submission time. A real QEMU
        # device would use address_space_* APIs and a documented DMA lifetime.
        owned_descriptor = Descriptor(
            tag=descriptor.tag,
            opcode=descriptor.opcode,
            left=tuple(descriptor.left[: descriptor.element_count]),
            right=tuple(descriptor.right[: descriptor.element_count]),
            element_count=descriptor.element_count,
        )
        self._pending.append(owned_descriptor)
        return CompletionStatus.SUCCESS

    def run_one(self) -> Completion | None:
        if not self._pending:
            return None

        descriptor = self._pending.pop(0)
        result = tuple(
            (left + right) & 0xFFFFFFFF
            for left, right in zip(descriptor.left, descriptor.right, strict=True)
        )
        completion = Completion(descriptor.tag, CompletionStatus.SUCCESS, result)
        self._completions.append(completion)
        return completion

    def reset(self) -> None:
        for descriptor in self._pending:
            self._completions.append(
                Completion(descriptor.tag, CompletionStatus.RESET)
            )
        self._pending.clear()

    def take_completions(self) -> list[Completion]:
        completions = self._completions
        self._completions = []
        return completions

    @staticmethod
    def _validate(descriptor: Descriptor) -> CompletionStatus | None:
        if descriptor.opcode != Opcode.VECTOR_ADD:
            return CompletionStatus.INVALID_OPCODE
        if not 0 < descriptor.element_count <= MAX_ELEMENTS:
            return CompletionStatus.INVALID_LENGTH
        if len(descriptor.left) < descriptor.element_count:
            return CompletionStatus.INVALID_LENGTH
        if len(descriptor.right) < descriptor.element_count:
            return CompletionStatus.INVALID_LENGTH
        return None
