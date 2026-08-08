#!/usr/bin/env bash
#
# flash.sh - build and upload a sketch, finding the board automatically.
#
#   ./flash.sh                 # flashes status_ble (the usual case)
#   ./flash.sh xy_test         # flashes a specific sketch
#   ./flash.sh status_ble -m   # flash, then open the serial monitor
#
# Exists because two things kept biting us by hand:
#
#   1. macOS names the port after the physical USB socket, so it changes every
#      time the board is replugged elsewhere. It has been usbserial-110, -10
#      and -210 so far. Hardcoding it guarantees a "port is busy or doesn't
#      exist" failure sooner or later.
#   2. This CH340 clone cannot handle the default 921600 baud, so the upload
#      speed must be pinned to 115200 every single time.

set -euo pipefail

SKETCH="${1:-status_ble}"
MONITOR="${2:-}"

FQBN="esp32:esp32:esp32:UploadSpeed=115200"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$REPO/$SKETCH" ]]; then
  echo "no such sketch: $SKETCH" >&2
  echo "available:" >&2
  find "$REPO" -maxdepth 2 -name '*.ino' -exec dirname {} \; | xargs -n1 basename | sort | sed 's/^/  /' >&2
  exit 1
fi

# Any USB serial port is our board; the Bluetooth and debug ports are not USB.
PORT="$(arduino-cli board list | awk '/usbserial|usbmodem|wchusbserial/ {print $1; exit}')"

if [[ -z "$PORT" ]]; then
  echo "no ESP32 found. Is it plugged in with a DATA usb cable?" >&2
  arduino-cli board list >&2
  exit 1
fi

echo "sketch : $SKETCH"
echo "port   : $PORT"
echo

arduino-cli compile --upload -p "$PORT" --fqbn "$FQBN" "$REPO/$SKETCH"

if [[ "$MONITOR" == "-m" || "$MONITOR" == "--monitor" ]]; then
  echo
  echo "opening monitor on $PORT (ctrl-c to exit)"
  arduino-cli monitor -p "$PORT" -c baudrate=115200
fi
