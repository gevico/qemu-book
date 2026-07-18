#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Functional oracle for the Chapter 26 toy matrix accelerator ABI."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
from typing import Sequence


MAX_DIMENSION = 16
MAX_ELEMENTS = MAX_DIMENSION * MAX_DIMENSION


class Status(IntEnum):
    SUCCESS = 0
    INVALID_SHAPE = 1
    INVALID_BUFFER = 2
    QUEUE_FULL = 3
    RESET = 4


@dataclass(frozen=True)
class MatmulDescriptor:
    tag: int
    rows: int
    inner: int
    columns: int
    left: Sequence[int]
    right: Sequence[int]


@dataclass(frozen=True)
class Completion:
    tag: int
    status: Status
    output: tuple[int, ...] = ()


class Accelerator:
    def __init__(self, queue_depth: int = 2) -> None:
        if queue_depth < 1:
            raise ValueError("queue_depth must be positive")
        self._queue_depth = queue_depth
        self._pending: list[MatmulDescriptor] = []
        self._completions: list[Completion] = []

    def submit(self, descriptor: MatmulDescriptor) -> Status:
        if len(self._pending) >= self._queue_depth:
            self._completions.append(Completion(descriptor.tag, Status.QUEUE_FULL))
            return Status.QUEUE_FULL

        error = self._validate(descriptor)
        if error is not None:
            self._completions.append(Completion(descriptor.tag, error))
            return error

        # Copy input data to model a request object with an explicit lifetime.
        self._pending.append(
            MatmulDescriptor(
                descriptor.tag,
                descriptor.rows,
                descriptor.inner,
                descriptor.columns,
                tuple(descriptor.left),
                tuple(descriptor.right),
            )
        )
        return Status.SUCCESS

    def execute_one(self) -> Completion | None:
        if not self._pending:
            return None
        descriptor = self._pending.pop(0)
        output: list[int] = []
        for row in range(descriptor.rows):
            for column in range(descriptor.columns):
                value = 0
                for index in range(descriptor.inner):
                    left = descriptor.left[row * descriptor.inner + index]
                    right = descriptor.right[index * descriptor.columns + column]
                    value = (value + left * right) & 0xFFFFFFFF
                output.append(value)
        completion = Completion(descriptor.tag, Status.SUCCESS, tuple(output))
        self._completions.append(completion)
        return completion

    def reset(self) -> None:
        for descriptor in self._pending:
            self._completions.append(Completion(descriptor.tag, Status.RESET))
        self._pending.clear()

    def take_completions(self) -> list[Completion]:
        completions = self._completions
        self._completions = []
        return completions

    @staticmethod
    def _validate(descriptor: MatmulDescriptor) -> Status | None:
        dimensions = (descriptor.rows, descriptor.inner, descriptor.columns)
        if any(value < 1 or value > MAX_DIMENSION for value in dimensions):
            return Status.INVALID_SHAPE

        left_elements = descriptor.rows * descriptor.inner
        right_elements = descriptor.inner * descriptor.columns
        output_elements = descriptor.rows * descriptor.columns
        if max(left_elements, right_elements, output_elements) > MAX_ELEMENTS:
            return Status.INVALID_SHAPE
        if len(descriptor.left) != left_elements:
            return Status.INVALID_BUFFER
        if len(descriptor.right) != right_elements:
            return Status.INVALID_BUFFER
        return None
