#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from queue_model import CommandQueue, CompletionStatus, Descriptor, Opcode


def vector_descriptor(tag: int, count: int = 2) -> Descriptor:
    return Descriptor(tag, Opcode.VECTOR_ADD, [1, 2], [10, 20], count)


class CommandQueueTests(unittest.TestCase):
    def test_vector_add(self) -> None:
        queue = CommandQueue(depth=2)
        self.assertEqual(queue.submit(vector_descriptor(7)), CompletionStatus.SUCCESS)
        completion = queue.run_one()
        self.assertIsNotNone(completion)
        self.assertEqual(completion.result, (11, 22))

    def test_invalid_length_is_completed_without_queueing(self) -> None:
        queue = CommandQueue()
        descriptor = vector_descriptor(8, count=3)
        self.assertEqual(queue.submit(descriptor), CompletionStatus.INVALID_LENGTH)
        self.assertEqual(queue.pending_count, 0)

    def test_unknown_opcode_is_rejected(self) -> None:
        queue = CommandQueue()
        descriptor = Descriptor(9, 0xFFFF, [1], [2], 1)
        self.assertEqual(queue.submit(descriptor), CompletionStatus.INVALID_OPCODE)

    def test_queue_full_is_bounded(self) -> None:
        queue = CommandQueue(depth=1)
        self.assertEqual(queue.submit(vector_descriptor(1)), CompletionStatus.SUCCESS)
        self.assertEqual(queue.submit(vector_descriptor(2)), CompletionStatus.QUEUE_FULL)
        self.assertEqual(queue.pending_count, 1)

    def test_reset_completes_in_flight_commands(self) -> None:
        queue = CommandQueue(depth=2)
        queue.submit(vector_descriptor(3))
        queue.reset()
        self.assertEqual(queue.pending_count, 0)
        self.assertIn(
            (3, CompletionStatus.RESET),
            [(entry.tag, entry.status) for entry in queue.take_completions()],
        )


if __name__ == "__main__":
    unittest.main()
