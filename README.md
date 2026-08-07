# glowgrid

Driving an LED matrix from an ESP32-WROOM-32 dev board (CH340 USB, 5V in / 3.3V logic).

## Hardware, confirmed

- **Board**: ESP32-D0WD-V3 rev v3.1, dual core, Wi-Fi + BT. MAC `b0:cb:d8:c1:84:90`.
  Port on this Mac: `/dev/cu.usbserial-110`.
- **Panel**: BTF-LIGHTING WS2812B ECO, **8x8 = 64 pixels**, 8x8 cm flexible FPCB, DC5V.
  Colour order is **GRB, not RGB**. Serpentine chain layout. Max ~19.2 W (~3.8 A) all white.

### IMPORTANT: upload speed

This board's CH340 clone cannot handle the default 921600 baud - the upload connects,
reads the chip ID, then dies with "Unable to verify flash chip connection". Always
upload at 115200:

```sh
arduino-cli compile --upload -p /dev/cu.usbserial-110 \
  --fqbn "esp32:esp32:esp32:UploadSpeed=115200" <sketch_dir>
```

In the Arduino IDE GUI: Tools > Upload Speed > 115200.

## Sketches

Each is a step that was verified before moving on, so any of them can be reflashed to
isolate a problem later.

- `blink_test/` - step 0, blinks the onboard LED only. No wiring needed. Proves board+cable.
- `matrix_test/` - step 1, first light on the panel. Power-limited, safe on USB.
- `xy_calibrate/` - step 2a, reveals the physical layout (which corner is index 0, row
  direction, serpentine or not).
- `xy_test/` - step 2b, validates the `XY()` mapper with a letter F, a top row, a left
  column and an origin pixel.
- `status_display/` - step 3, the five availability states on a timer. No Bluetooth.
- `status_ble/` - step 4, the same display driven over BLE. **This is the current one.**

## Measured panel layout

Determined empirically in step 2, not assumed:

- chain index 0 is the **bottom-left** corner
- the chain runs in **horizontal rows of 8**
- the bottom row runs **left to right**, and each row above reverses (**serpentine**)

`XY(x, y)` exposes a normal screen coordinate system on top of that - origin top-left,
x right, y down - by flipping vertically and undoing the serpentine. Everything above
that layer can pretend the panel is an ordinary grid.

## BLE interface

```
device name  glowgrid
service      6E400001-B5A3-F393-E0A9-E50E24DCCA9E
RX (write)   6E400002-B5A3-F393-E0A9-E50E24DCCA9E
```

Write one of `available`, `busy`, `meeting`, `away`, `off` as plain ASCII. Digits `0`-`4`
work too. Those are the Nordic UART Service UUIDs, chosen so generic BLE apps recognise
the device for testing.

A dim blue dot in the bottom-right corner means no client is connected. That indicator
exists so "nothing connected" and "status off" are not visually identical.

## Mac CLI

```sh
cd mac-cli
./glowgrid.py available
./glowgrid.py busy
./glowgrid.py --scan      # list nearby BLE devices
./glowgrid.py --forget    # clear the cached device address
```

The script carries PEP 723 inline dependency metadata, so `uv` builds its environment on
the fly - nothing to install, no venv to activate. The device address is cached in
`~/.cache/glowgrid/address`, which cuts a status change from ~8s to ~1.5s; it falls back
to scanning automatically if the cached address stops working.

**macOS needs Bluetooth permission** for the terminal app (System Settings > Privacy &
Security > Bluetooth). Without it the process dies with `SIGABRT` and no useful message.

Note: macOS deliberately does not support classic Bluetooth serial (SPP), which is why
this is BLE. It also hides hardware MAC addresses, so the "address" is a CoreBluetooth
UUID that is stable per machine but differs on another Mac.

### Installed commands

Both are symlinks into `~/.local/bin`, which is already on PATH:

```sh
glowgrid busy         # set a status from anywhere
glowgrid-watch        # run the automatic watcher
```

## Automatic status detection

`glowgrid-watch` polls the camera and microphone and maps them to a status:

- camera in use -> `meeting`
- mic in use, no camera -> `busy`
- neither -> `available`

```sh
glowgrid-watch                 # foreground
glowgrid-watch --dry-run       # decide but never touch the panel
glowgrid-watch --interval 5    # seconds between samples (default 3)
glowgrid-watch --on-exit off   # what to leave on the panel on Ctrl+C
```

It only sends on a *change* of state, and requires a new state to be seen twice before
acting. Both matter: re-sending constantly would thrash the BLE link, and mic state
briefly blips when apps probe the device, which made the panel flap colours.

### How detection works, and why not the easy way

`mac-cli/media-sensor/media_sensor.swift` compiles to a small binary that queries:

- `kAudioDevicePropertyDeviceIsRunningSomewhere` (CoreAudio) for the microphone
- `kCMIODevicePropertyDeviceIsRunningSomewhere` (CoreMediaIO) for the camera

These are the supported "is this device running for anybody" properties. Two tempting
alternatives were rejected: scraping `log stream` relies on private subsystem names that
change between macOS releases, and looking for processes named zoom/teams only proves the
app is open, not that it is capturing.

It needs **no camera or microphone permission**, because it never touches media - it only
asks about device state. So no TCC prompt for this binary.

Output-only audio devices are skipped explicitly, otherwise playing music would register
as microphone activity and show you as busy.

Rebuild after editing:

```sh
cd mac-cli
swiftc -O media-sensor/media_sensor.swift -o bin/media-sensor
```

Verified: camera flips 0 -> 1 -> 0 around opening and closing Photo Booth. Microphone
detection uses the analogous property but has not yet been confirmed on a real call.

## Powering from a USB battery

The plan is to keep the current wiring (panel on `VIN`) and run the whole thing from a
USB-C power bank. That works, with one caveat worth knowing before you buy anything.

- **Current is not the problem.** ESP32 with BLE averages ~80-150 mA, and the panel at
  `BRIGHTNESS 15` with a glyph lit is only tens of mA. Any power bank supplies that
  easily - more headroom than you have now.
- **The real risk is auto-shutoff.** Many power banks switch themselves off when draw
  falls below roughly 50-100 mA, because they assume nothing is plugged in. Our load sits
  near that threshold, so some banks will cut out after a few minutes. Look for one
  advertising a low-current, trickle or "small device" mode. This is the single thing
  that decides whether the idea works.
- **Runtime is fine.** A 10,000 mAh bank yields roughly 6,000-7,000 mAh usable after
  conversion losses, so at ~150 mA you get well over a day.
- **Trade-off:** on battery there is no serial console, and reflashing means going back
  to the Mac. Do not feed `VIN` from an external supply while USB is also connected.

If a bank does cut out on you, raising `BRIGHTNESS` is the crude fix - it increases draw
above the cutoff and looks better anyway.

## Gotchas already paid for

- **Upload speed.** The CH340 clone fails at the default 921600. Always 115200.
- **`arduino-cli upload` does not compile.** Use `arduino-cli compile --upload`.
- **Arduino injects function prototypes** above the first function definition, so any
  `enum` used in a function signature must be declared before that point.
- **Do not name an enum `Status`** in a sketch that uses BLE. `BLECharacteristicCallbacks`
  has a nested `Status`, which shadows yours inside derived classes and produces a very
  confusing error. Ours is called `Presence`.
- **The serial monitor is not a reliable liveness check.** With BLE running, output can
  freeze at the bootloader `configsip:` line while the sketch is in fact running
  perfectly. Trust an observable side effect (the blue dot, or a BLE scan) instead. This
  cost real time chasing an imaginary boot failure.
- **`status_ble` is at 93% of the default app partition.** Adding much more code will
  need `PartitionScheme=huge_app`, and after changing partition scheme you should
  `erase_flash` before reflashing.

## Status: software side is DONE

Already installed and verified on this Mac:

- `arduino-cli` 1.5.1 + Arduino IDE 2 (they share `~/Library/Arduino15`, so configuring
  one configures both)
- Espressif board index registered in `~/Library/Arduino15/arduino-cli.yaml`
- `esp32:esp32@3.3.11` core installed -> "ESP32 Dev Module" is selectable
- `FastLED@3.10.5` library installed
- `glowgrid.ino` compiles for `esp32:esp32:esp32`

Note: the board index URL in the manual (`dl.espressif.com/dl/package_esp32_index.json`)
is the old one. We used the current canonical URL:
`https://espressif.github.io/arduino-esp32/package_esp32_index.json`

## Step 0 - prove the board works (do this first, no wiring)

Plug the ESP32 into USB with a **data** cable (not a charge-only cable), then:

```sh
# 1. find the port - look for something like /dev/cu.usbserial-XXXX or /dev/cu.wchusbserialXXXX
arduino-cli board list

# 2. upload (replace the port with what you saw above)
arduino-cli upload -p /dev/cu.usbserial-0001 --fqbn esp32:esp32:esp32 .

# 3. watch the serial output
arduino-cli monitor -p /dev/cu.usbserial-0001 -c baudrate=115200
```

The small LED on the board should blink once per second and you should see
`on` / `off` in the monitor.

### If the port does not show up

That is the CH340 driver issue the manual mentions. macOS has a built-in CH34x driver,
but many cheap clones need the vendor one:

```sh
brew install --cask wch-ch34x-usb-serial-driver
```

Then reboot and allow the kernel extension in System Settings > Privacy & Security.

### If upload hangs at "Connecting........"

Hold the **BOOT** button on the board while the upload starts, release once it begins
writing. Some clones do not auto-reset.

## Step 1 - wiring the matrix (only after step 0 passes)

Unplug USB before touching any wires.

| ESP32 pin | Wire     | Matrix pin |
|-----------|----------|------------|
| `VIN`     | power    | `5V` / `VCC` |
| `GND`     | ground   | `GND`      |
| `D13`     | data     | `DIN`      |

`GPIO13` is the data pin in code (`D13` silkscreen == `GPIO13`).

### Identifying the three wire sets on the back of the panel

The panel has three sets of wires. Only one is the input:

1. **Arrow one way, `5V`/`GND`/`DOUT`, male connector** - the OUTPUT, for chaining a
   second panel. **Not used.**
2. **Two bare `5V`/`GND` wires, no connector** - power injection, for an external 5V
   supply. Use these later when you want real brightness.
3. **Arrow the other way, `5V`/`GND`/`DIN`, female connector** - the **INPUT. Use this.**

The rule: data goes IN at `DIN`. `DOUT` is an exit. The arrows point opposite ways
because the LED chain snakes back and forth row by row (serpentine) - which also means
row 1 runs left-to-right, row 2 right-to-left, and so on. That matters once we start
drawing images rather than lighting single pixels.

### Confirmed wire colours (verified by tracing, not assumed)

The JST pigtail adapter is straight-through, so colours hold on both sides:

- **red = 5V** -> ESP32 `VIN`
- **white = GND** -> ESP32 `GND`
- **green = DIN** -> ESP32 `D13` (GPIO13)

Note: when you hold two mated connectors face to face the colour order *looks* reversed.
That is a mirror effect, not a real swap. Adapter colours are not guaranteed in general -
verify by slot position or with a continuity test before trusting them on any new part.

### Bare wire ends into dupont sockets

The adapter ends in bare copper, joined to female-female dupont leads. That is a loose
friction fit, so:

- Twist each bare end tightly before inserting, and push it fully in.
- Keep the three bare joints physically apart so they cannot touch each other.
- Intermittent contact on the data line shows up as flicker or wrong colours; intermittent
  power shows up as the panel resetting. If you see either, suspect these joints first.
- Tinning the bare ends with solder makes them far more reliable if you have an iron.

### Power warning - read this, it matters

`VIN` on this board is just passed straight through from the USB 5V rail. USB gives
you roughly 500 mA. A WS2812 LED draws up to ~60 mA at full white, so:

- **8x8 panel (64 LEDs) at full white = ~3.8 A.** Far beyond USB.
- Powering a matrix from `VIN` only works if you keep brightness low.

So for the first test, cap brightness hard (`FastLED.setBrightness(20)` or lower) and
light only a few LEDs. If you want the panel at real brightness, feed the panel from a
separate 5V supply and connect only `GND` + `D13` from the ESP32 (grounds must be common).

Also worth knowing: the ESP32 outputs 3.3V logic and WS2812 wants ~4V on DIN. It
usually works anyway on short wires, but if the colours are glitchy that is why - a
level shifter fixes it.

## Which matrix do you have?

The wiring above (`5V` / `GND` / `DIN`) means a WS2812B / NeoPixel style panel, which
is what FastLED drives. If your panel instead has `VCC / GND / DIN / CS / CLK`, it is a
MAX7219 module and needs a different library (`LedControl`) - say so and we will swap it.

## Handy commands

```sh
arduino-cli compile --fqbn esp32:esp32:esp32 .
arduino-cli upload -p <PORT> --fqbn esp32:esp32:esp32 .
arduino-cli monitor -p <PORT> -c baudrate=115200
```

In the Arduino IDE GUI instead: open `glowgrid.ino`, pick **ESP32 Dev Module** and the
port from the toolbar dropdown, then hit Upload.
