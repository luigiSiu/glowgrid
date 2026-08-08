#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["bleak>=0.22"]
# ///
"""
glowgrid - control the ESP32 LED panel over Bluetooth LE.

Usage:
    ./glowgrid.py available
    ./glowgrid.py busy
    ./glowgrid.py meeting
    ./glowgrid.py away
    ./glowgrid.py off

    ./glowgrid.py --text "BACK IN 5"   scroll a message
    ./glowgrid.py --clear              stop scrolling, show the status again
    ./glowgrid.py --brightness 12      set brightness (1-60)
    ./glowgrid.py --brighter           step brightness up
    ./glowgrid.py --dimmer             step brightness down
    ./glowgrid.py --raw "b:20"         send any command verbatim

    ./glowgrid.py --scan          list nearby BLE devices
    ./glowgrid.py --forget        clear the cached device address

The dependency block at the top is PEP 723 inline script metadata. `uv` reads
it and builds a throwaway environment on the fly, so there is no venv to
create or activate and nothing is installed into your system Python.

macOS note: the terminal application needs Bluetooth permission
(System Settings > Privacy & Security > Bluetooth). Without it the process is
killed with SIGABRT rather than getting a clean error, which is confusing the
first time you hit it.
"""

import argparse
import asyncio
import sys
from pathlib import Path

from bleak import BleakClient, BleakScanner

DEVICE_NAME = "glowgrid"
CHAR_RX_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

STATUSES = ["available", "busy", "meeting", "away", "off"]

# Scanning takes several seconds, which is far too slow for something you may
# call from a shortcut. macOS device identifiers are stable per machine, so we
# remember the address and only fall back to scanning when it stops working.
CACHE_PATH = Path.home() / ".cache" / "glowgrid" / "address"


def read_cached_address() -> str | None:
    try:
        return CACHE_PATH.read_text().strip() or None
    except FileNotFoundError:
        return None


def write_cached_address(address: str) -> None:
    CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    CACHE_PATH.write_text(address)


async def find_device(timeout: float = 10.0):
    print(f"scanning for '{DEVICE_NAME}'...", file=sys.stderr)
    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=timeout)
    if device is None:
        return None
    write_cached_address(device.address)
    return device




async def send_command(command: str) -> int:
    """
    Connect and write one command verbatim. Returns a process exit code.

    The firmware accepts bare status words plus prefixed commands (b:, b+, b-,
    t:, clear), so this one function covers everything the panel understands.
    """
    payload = command.encode()

    target = read_cached_address()
    if target:
        # Try the cached address first. This is the fast path.
        try:
            async with BleakClient(target, timeout=10.0) as client:
                await client.write_gatt_char(CHAR_RX_UUID, payload, response=True)
                print(f"sent: {command}")
                return 0
        except Exception as exc:
            print(f"cached address failed ({exc}), rescanning...", file=sys.stderr)

    device = await find_device()
    if device is None:
        print(
            f"could not find '{DEVICE_NAME}'. Is the board powered on?",
            file=sys.stderr,
        )
        return 1

    try:
        async with BleakClient(device, timeout=10.0) as client:
            await client.write_gatt_char(CHAR_RX_UUID, payload, response=True)
            print(f"sent: {command}")
            return 0
    except Exception as exc:
        print(f"failed to send: {exc}", file=sys.stderr)
        return 1


async def scan() -> int:
    print("scanning for 8s...")
    devices = await BleakScanner.discover(timeout=8.0)
    for d in sorted(devices, key=lambda d: (d.name or "~")):
        marker = " <-- glowgrid" if d.name == DEVICE_NAME else ""
        print(f"  {d.name or '(unnamed)':<28} {d.address}{marker}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Control the glowgrid LED panel over BLE."
    )
    parser.add_argument(
        "status", nargs="?", choices=STATUSES, help="status to display"
    )
    parser.add_argument("--text", metavar="MESSAGE", help="scroll a message")
    parser.add_argument(
        "--clear", action="store_true", help="stop scrolling, show the status"
    )
    parser.add_argument(
        "--brightness", type=int, metavar="N", help="set brightness (1-60)"
    )
    parser.add_argument("--brighter", action="store_true", help="step brightness up")
    parser.add_argument("--dimmer", action="store_true", help="step brightness down")
    parser.add_argument("--raw", metavar="CMD", help="send a command verbatim")
    parser.add_argument(
        "--scan", action="store_true", help="list nearby BLE devices and exit"
    )
    parser.add_argument(
        "--forget", action="store_true", help="clear the cached device address"
    )
    args = parser.parse_args()

    if args.forget:
        CACHE_PATH.unlink(missing_ok=True)
        print("cached address cleared")
        return 0

    if args.scan:
        return asyncio.run(scan())

    # Resolve whichever option was given into a single wire command.
    command: str | None = None
    if args.raw:
        command = args.raw
    elif args.text:
        command = f"t:{args.text}"
    elif args.clear:
        command = "clear"
    elif args.brightness is not None:
        command = f"b:{args.brightness}"
    elif args.brighter:
        command = "b+"
    elif args.dimmer:
        command = "b-"
    elif args.status:
        command = args.status

    if command is None:
        parser.print_help()
        return 2

    return asyncio.run(send_command(command))


if __name__ == "__main__":
    sys.exit(main())
