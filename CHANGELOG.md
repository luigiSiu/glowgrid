# Changelog

What changed in each release, and where it is worth knowing why. Newest first.

Loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
[semantic versioning](https://semver.org/) — though while this is at `0.x` the
minor number is doing the work of a major one.

Version numbers live in three places that have to agree: `Info.plist`,
`pyproject.toml` and the git tag. See
[Version numbers, and where they live](README.md#version-numbers-and-where-they-live).

## [0.1.0] — 2026-08-25

First release. The panel has been on a desk doing its job for a few weeks; this
is the point at which somebody else can install it without compiling anything.

### The panel

- **Firmware** (`status_ble/`) for an ESP32 driving a 64-pixel WS2812B matrix:
  five states, each an animated icon that scales in from the centre and then
  breathes, plus scrolling text up to 160 characters.
- **Brightness** is settable from 1 to 60, saved to non-volatile storage and
  restored on boot. Written only when it actually changes, because flash has
  finite write cycles.
- **Bluetooth LE control** using the Nordic UART Service UUIDs, so generic BLE
  apps can drive the panel with no client code — which is how the protocol was
  tested before any Mac code existed.
- **Advertising continues while connected**, so several clients can talk to the
  panel at once. This also fixes a fault that looked exactly like dead
  hardware: with the app connected, the panel had been vanishing from every
  scan.
- **Power is capped deliberately** — brightness defaults to 6 of 255 and FastLED
  is limited to 300 mA, so the whole thing runs safely off USB. A 64-pixel panel
  at full white would want about 3.8 A, roughly eight times what USB provides.

### The Mac app

- **Menu bar app** (`mac-app/`, Swift, no Xcode project) that connects over BLE
  and holds the connection open.
- **Automatic mode** follows the Mac: camera in use means *in a meeting*,
  microphone in use means *busy*, neither means *available*. Read from device
  state via CoreAudio and CoreMediaIO, so it needs no camera or microphone
  permission.
- **Optional calendar awareness**, covering the case neither sensor sees: the
  first minutes of a meeting, when you are still walking to a room. All-day,
  Free, cancelled and declined events are ignored. Nothing leaves the Mac.
- **Manual and Automatic are explicit modes**, not a manual choice that expires
  on a timer. A panel that changes state with no visible cause feels haunted.
- **Brightness, scrolling text, panel picker and launch-at-login**, with the
  brightness value read back from the panel itself so it stays correct if
  something else changed it.
- **Reconnects on its own** after the panel loses power or wanders out of range,
  and restores the status it was showing.
- **Universal binary**, Apple Silicon and Intel, macOS 13 or later.
- **Signed with a Developer ID certificate and notarised by Apple**, so the
  download opens with a double click — no right-click-Open, no warning dialog.
  `mac-app/release.sh` does the signing, notarising, stapling and zipping.

### Command line

- `mac-cli/glowgrid.py` for scripting status, brightness and text, with the
  device address cached to cut a status change from about 8 s to 1.5 s.
- `mac-cli/glowgrid-watch.py`, the original camera/microphone watcher, kept as
  the reference implementation of the detection logic. Superseded by the app.

### Documentation

- The README is a build guide rather than a description: real bill of materials
  with prices and links, wiring photos with the silkscreen legible, the photo
  frame enclosure, and the mistakes that cost the most time.

### Known limitations

- **Bluetooth range is noticeably shorter on battery.** On USB the panel held a
  connection from over two metres away through a wall; with a power bank behind
  the frame it wants to be within about a metre, in sight of the Mac. The
  battery sits in the antenna's near field and its regulator raises the noise
  floor. Observed, not measured — see
  [the battery section](README.md#the-battery-costs-you-bluetooth-range).
- **`status_ble` occupies about 94% of the default app partition.** It fits, but
  there is not much room for new features without changing the partition scheme.
- **The panel is trusted, not authenticated.** Anything within Bluetooth range
  can set your status. For a light on your own desk that is the right trade-off,
  but it is a trade-off.
- **The Mac app has no automated tests.** It was built by hand and verified by
  watching a physical panel, which is honest but does not scale.

[0.1.0]: https://github.com/luigiSiu/glowgrid/releases/tag/v0.1.0
