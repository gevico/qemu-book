#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run a matching or deliberately mismatched RISC-V TCG migration pair."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import socket
import subprocess
import time
from typing import Any

COUNTER = re.compile(r"^counter=([0-9a-f]{16})$", re.MULTILINE)
RESULTS_MARKER = ".qemu-book-migration-results"
LOG_NAMES = (
    "source.serial",
    "source.stderr",
    "destination.serial",
    "destination.stderr",
)
SOCKET_NAMES = ("source.qmp", "destination.qmp", "migration.sock")


def parse_counters(text: str) -> list[int]:
    return [int(match, 16) for match in COUNTER.findall(text)]


class QMPClient:
    def __init__(self, path: pathlib.Path, timeout: float = 10.0) -> None:
        deadline = time.monotonic() + timeout
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        while True:
            try:
                self.socket.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"QMP socket did not become ready: {path}")
                time.sleep(0.05)
        self.stream = self.socket.makefile("rwb")
        greeting = self._read_message()
        if "QMP" not in greeting:
            raise RuntimeError(f"unexpected QMP greeting: {greeting}")
        self.command("qmp_capabilities")

    def _read_message(self) -> dict[str, Any]:
        line = self.stream.readline()
        if not line:
            raise EOFError("QMP connection closed")
        return json.loads(line)

    def command(self, execute: str, arguments: dict[str, Any] | None = None) -> Any:
        request: dict[str, Any] = {"execute": execute}
        if arguments:
            request["arguments"] = arguments
        self.stream.write(json.dumps(request).encode("utf-8") + b"\r\n")
        self.stream.flush()
        while True:
            response = self._read_message()
            if "event" in response:
                continue
            if "error" in response:
                raise RuntimeError(f"QMP {execute} failed: {response['error']}")
            if "return" in response:
                return response["return"]

    def close(self) -> None:
        self.stream.close()
        self.socket.close()


def wait_for_counters(path: pathlib.Path, minimum: int, timeout: float) -> list[int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            counters = parse_counters(path.read_text(encoding="utf-8", errors="replace"))
            if len(counters) >= minimum:
                return counters
        time.sleep(0.1)
    raise TimeoutError(f"fewer than {minimum} counters appeared in {path}")


def wait_for_migration(client: QMPClient, timeout: float) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = client.command("query-migrate").get("status", "unknown")
        if status in {"completed", "failed", "cancelled"}:
            return status
        time.sleep(0.1)
    raise TimeoutError("migration did not reach a terminal state")


def prepare_results_directory(results: pathlib.Path) -> None:
    """Validate ownership boundaries, then remove only stale lab sockets."""

    if results.exists() and not results.is_dir():
        raise ValueError(f"results path is not a directory: {results}")

    marker = results / RESULTS_MARKER
    if marker.is_symlink():
        raise ValueError(f"refusing a symlinked results marker: {marker}")
    if results.exists() and any(results.iterdir()) and not marker.is_file():
        raise ValueError(
            f"refusing to overwrite non-empty unmarked results directory: {results}"
        )

    log_paths = [results / name for name in LOG_NAMES]
    socket_paths = [results / name for name in SOCKET_NAMES]
    for log_path in log_paths:
        if log_path.is_symlink() or (log_path.exists() and not log_path.is_file()):
            raise ValueError(f"refusing to replace a non-regular log path: {log_path}")
    for socket_path in socket_paths:
        if socket_path.is_symlink() or (
            socket_path.exists() and not socket_path.is_socket()
        ):
            raise ValueError(f"refusing to replace a non-socket path: {socket_path}")

    results.mkdir(parents=True, exist_ok=True)
    marker.touch(exist_ok=True)
    for socket_path in socket_paths:
        socket_path.unlink(missing_ok=True)


def launch(
    qemu: pathlib.Path,
    guest: pathlib.Path,
    qmp_socket: pathlib.Path,
    serial_log: pathlib.Path,
    stderr_log: pathlib.Path,
    memory: str,
    incoming: bool,
) -> subprocess.Popen[bytes]:
    command = [
        str(qemu),
        "-machine", "virt",
        "-cpu", "rv64",
        "-accel", "tcg,thread=single",
        "-smp", "1",
        "-m", memory,
        "-bios", "none",
        "-kernel", str(guest),
        "-display", "none",
        "-serial", f"file:{serial_log}",
        "-monitor", "none",
        "-qmp", f"unix:{qmp_socket},server=on,wait=off",
        "-no-reboot",
    ]
    if incoming:
        command += ["-incoming", "defer"]
    with stderr_log.open("wb") as stderr:
        return subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=stderr)


def stop(client: QMPClient | None, process: subprocess.Popen[bytes] | None) -> None:
    if client is not None:
        try:
            client.command("quit")
        except (EOFError, OSError, RuntimeError):
            pass
        client.close()
    if process is not None:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", type=pathlib.Path, required=True)
    parser.add_argument("--guest", type=pathlib.Path, default=pathlib.Path("build/counter.elf"))
    parser.add_argument("--results", type=pathlib.Path, default=pathlib.Path("results"))
    parser.add_argument("--expect-mismatch", action="store_true")
    args = parser.parse_args()

    qemu = args.qemu.resolve()
    guest = args.guest.resolve()
    results = args.results.resolve()
    if not qemu.is_file() or not os.access(qemu, os.X_OK):
        raise SystemExit("QEMU binary is missing or not executable")
    if not guest.is_file():
        raise SystemExit("guest ELF is missing")

    source_qmp_path = results / "source.qmp"
    destination_qmp_path = results / "destination.qmp"
    migration_path = results / "migration.sock"
    try:
        prepare_results_directory(results)
    except ValueError as error:
        raise SystemExit(str(error)) from error

    source_process = destination_process = None
    source_qmp = destination_qmp = None
    try:
        destination_process = launch(
            qemu, guest, destination_qmp_path, results / "destination.serial",
            results / "destination.stderr", "192M" if args.expect_mismatch else "128M", True,
        )
        source_process = launch(
            qemu, guest, source_qmp_path, results / "source.serial",
            results / "source.stderr", "128M", False,
        )
        destination_qmp = QMPClient(destination_qmp_path)
        source_qmp = QMPClient(source_qmp_path)
        source_before = wait_for_counters(results / "source.serial", 2, 20)

        uri = f"unix:{migration_path}"
        destination_qmp.command("migrate-incoming", {"uri": uri})
        source_qmp.command("migrate", {"uri": uri})
        source_status = wait_for_migration(source_qmp, 30)

        if args.expect_mismatch:
            if source_status != "failed":
                raise RuntimeError(f"mismatched migration unexpectedly ended as {source_status}")
            print("mismatch_rejected=true")
            return

        destination_status = wait_for_migration(destination_qmp, 30)
        if (source_status, destination_status) != ("completed", "completed"):
            raise RuntimeError(
                f"migration statuses: source={source_status}, destination={destination_status}"
            )

        destination_after = wait_for_counters(results / "destination.serial", 2, 20)
        if destination_after[-1] <= source_before[-1]:
            raise RuntimeError("guest counter did not advance after migration")
        print(f"source_last=0x{source_before[-1]:016x}")
        print(f"destination_last=0x{destination_after[-1]:016x}")
        print("migration_completed=true")
    finally:
        stop(source_qmp, source_process)
        stop(destination_qmp, destination_process)


if __name__ == "__main__":
    main()
