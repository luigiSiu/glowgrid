#!/usr/bin/env python3
"""
glowgrid-watch - drive the panel automatically from camera/microphone usage.

    camera in use            -> meeting   (purple monitor)
    mic in use, no camera    -> busy      (red bar)
    neither                  -> available (green tick)

Usage:
    ./glowgrid-watch.py                 run in the foreground
    ./glowgrid-watch.py --dry-run       print decisions, never touch the panel
    ./glowgrid-watch.py --interval 5    seconds between samples (default 3)
    ./glowgrid-watch.py --on-exit off   status to leave behind on Ctrl+C

Deliberately uses only the standard library, so it runs on plain python3 with
nothing to install. The Bluetooth work is delegated to the `glowgrid` command,
which keeps the BLE logic in exactly one place.

Design notes:

- Only sends on CHANGE. Re-sending the same status every few seconds would
  hammer the BLE link for no benefit and make the connection indicator flicker
  constantly.

- Debounced. Mic state can blip for a fraction of a second when apps probe the
  device, so a new state must be observed twice in a row before it is
  believed. Without this the panel flaps between colours.

- Failures are non-fatal. If the board is off or out of range the send fails,
  we keep the last successfully applied state and retry on the next change.
"""

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SENSOR = HERE / "bin" / "media-sensor"

STATUS_AVAILABLE = "available"
STATUS_BUSY = "busy"
STATUS_MEETING = "meeting"


def read_sensor() -> tuple[bool, bool] | None:
    """Return (camera_in_use, mic_in_use), or None if the sensor failed."""
    try:
        out = subprocess.run(
            [str(SENSOR)], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"sensor error: {exc}", file=sys.stderr)
        return None

    if out.returncode != 0:
        print(f"sensor exited {out.returncode}: {out.stderr.strip()}", file=sys.stderr)
        return None

    camera = mic = False
    for token in out.stdout.split():
        key, _, value = token.partition("=")
        if key == "camera":
            camera = value == "1"
        elif key == "mic":
            mic = value == "1"
    return camera, mic


def decide(camera: bool, mic: bool) -> str:
    if camera:
        return STATUS_MEETING
    if mic:
        return STATUS_BUSY
    return STATUS_AVAILABLE


def apply_status(status: str, dry_run: bool) -> bool:
    """Push a status to the panel. Returns True if it was applied."""
    if dry_run:
        print(f"[dry-run] would set {status}")
        return True

    glowgrid = shutil.which("glowgrid") or str(HERE / "glowgrid.py")
    try:
        result = subprocess.run(
            [glowgrid, status], capture_output=True, text=True, timeout=60
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"send failed: {exc}", file=sys.stderr)
        return False

    if result.returncode != 0:
        print(f"send failed: {result.stderr.strip()}", file=sys.stderr)
        return False

    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Drive the glowgrid panel from camera/mic usage."
    )
    parser.add_argument("--interval", type=float, default=3.0,
                        help="seconds between samples (default 3)")
    parser.add_argument("--dry-run", action="store_true",
                        help="print decisions without touching the panel")
    parser.add_argument("--on-exit", default="off",
                        choices=["off", "available", "busy", "meeting", "away", "none"],
                        help="status to leave on Ctrl+C (default off)")
    args = parser.parse_args()

    if not SENSOR.exists():
        print(f"missing sensor binary: {SENSOR}", file=sys.stderr)
        print("build it with:", file=sys.stderr)
        print("  swiftc -O media-sensor/media_sensor.swift -o bin/media-sensor",
              file=sys.stderr)
        return 1

    print(f"watching camera/mic every {args.interval}s - Ctrl+C to stop")

    applied: str | None = None      # last status the panel actually accepted
    candidate: str | None = None    # state seen once, awaiting confirmation

    try:
        while True:
            reading = read_sensor()
            if reading is not None:
                camera, mic = reading
                wanted = decide(camera, mic)

                if wanted == applied:
                    candidate = None
                elif wanted == candidate:
                    # Seen twice in a row, so treat it as real.
                    detail = f"camera={int(camera)} mic={int(mic)}"
                    print(f"{time.strftime('%H:%M:%S')}  {detail}  -> {wanted}")
                    if apply_status(wanted, args.dry_run):
                        applied = wanted
                    candidate = None
                else:
                    candidate = wanted

            time.sleep(args.interval)

    except KeyboardInterrupt:
        print()
        if args.on_exit != "none":
            print(f"setting {args.on_exit} on the way out")
            apply_status(args.on_exit, args.dry_run)
        return 0


if __name__ == "__main__":
    sys.exit(main())
