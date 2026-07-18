#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

import unittest

from accelerator_model import Accelerator, MatmulDescriptor, Status


def valid_descriptor(tag: int) -> MatmulDescriptor:
    return MatmulDescriptor(
        tag=tag,
        rows=2,
        inner=2,
        columns=2,
        left=[1, 2, 3, 4],
        right=[5, 6, 7, 8],
    )


class AcceleratorModelTests(unittest.TestCase):
    def test_matrix_multiply(self) -> None:
        accelerator = Accelerator()
        self.assertEqual(accelerator.submit(valid_descriptor(1)), Status.SUCCESS)
        completion = accelerator.execute_one()
        self.assertIsNotNone(completion)
        self.assertEqual(completion.output, (19, 22, 43, 50))

    def test_invalid_shape_is_rejected(self) -> None:
        descriptor = MatmulDescriptor(2, 0, 2, 2, [], [1, 2, 3, 4])
        accelerator = Accelerator()
        self.assertEqual(accelerator.submit(descriptor), Status.INVALID_SHAPE)

    def test_invalid_buffer_is_rejected(self) -> None:
        descriptor = MatmulDescriptor(3, 2, 2, 2, [1], [1, 2, 3, 4])
        accelerator = Accelerator()
        self.assertEqual(accelerator.submit(descriptor), Status.INVALID_BUFFER)

    def test_queue_is_bounded(self) -> None:
        accelerator = Accelerator(queue_depth=1)
        self.assertEqual(accelerator.submit(valid_descriptor(4)), Status.SUCCESS)
        self.assertEqual(accelerator.submit(valid_descriptor(5)), Status.QUEUE_FULL)

    def test_reset_completes_pending_request(self) -> None:
        accelerator = Accelerator()
        accelerator.submit(valid_descriptor(6))
        accelerator.reset()
        self.assertIn(
            (6, Status.RESET),
            [(entry.tag, entry.status) for entry in accelerator.take_completions()],
        )


if __name__ == "__main__":
    unittest.main()
