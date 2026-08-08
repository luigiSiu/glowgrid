/*
 * glowgrid - step 4: status display driven over Bluetooth LE
 *
 * Same display as step 3, but the status now comes from BLE instead of a
 * timer. Write one of these ASCII strings to the RX characteristic:
 *
 *     available | busy | meeting | away | off
 *
 * Single digits 0-4 work too, in that same order, which is handy when
 * poking at it from a generic BLE app.
 *
 * BLE identity:
 *   device name  glowgrid
 *   service      6E400001-B5A3-F393-E0A9-E50E24DCCA9E
 *   RX (write)   6E400002-B5A3-F393-E0A9-E50E24DCCA9E
 *
 * Those are the Nordic UART Service UUIDs. They are not required for our
 * purposes, but using a well-known service means generic phone apps such as
 * nRF Connect or LightBlue recognise the device, which makes testing much
 * easier before any Mac code exists.
 *
 * NOTE: this sketch must be built with the huge_app partition scheme.
 * BLE plus FastLED does not fit in the default 1.3 MB app partition:
 *
 *   arduino-cli compile --upload -p <PORT> \
 *     --fqbn "esp32:esp32:esp32:UploadSpeed=115200,PartitionScheme=huge_app" \
 *     status_ble
 */

#include <FastLED.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define DATA_PIN    13
#define NUM_LEDS    64
#define MATRIX_W    8
#define MATRIX_H    8

/*
 * Walked 15 -> 8 -> 4 -> 6. These panels are fierce at desk distance: bright
 * pixels bloom into their neighbours and the shape turns into a glowing blob,
 * so less brightness genuinely reads BETTER close up. 4 was slightly too dim,
 * 6 is the sweet spot. Single digits are normal here.
 */
#define BRIGHTNESS  6
#define MAX_MILLIAMPS 300

// How long an icon takes to draw itself in, in milliseconds.
#define ANIM_MS 700

/*
 * Idle animation, i.e. what the icon does once it has finished appearing.
 *
 * Two effects layered together:
 *   - a slow breathe, so the panel looks alive rather than switched on
 *   - a highlight that sweeps diagonally across the glyph now and then
 *
 * Both are deliberately restrained. This thing sits on a desk all day, so
 * anything faster or wider reads as "broken" and becomes annoying fast. The
 * breathe never dims below ~80%, which keeps it from looking like a flicker.
 */
#define IDLE_FRAME_MS      25      // ~40 fps
#define BREATHE_BPM        20      // roughly a 3 second cycle
#define BREATHE_MIN        205     // out of 255, so a shallow dip
#define SHIMMER_PERIOD_MS  3800    // how often a sweep happens
#define SHIMMER_SWEEP_MS   900     // how long one sweep takes
#define SHIMMER_WIDTH      0.22f   // width of the highlight band
#define SHIMMER_STRENGTH   150     // how white the highlight goes, 0-255

#define DEVICE_NAME "glowgrid"
#define SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHAR_RX_UUID "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

CRGB leds[NUM_LEDS];

/*
 * Declared before any function: Arduino injects generated prototypes above the
 * first function definition, so types used in signatures must exist here.
 *
 * Named Presence rather than the more obvious Status on purpose.
 * BLECharacteristicCallbacks declares its own nested `Status` enum, which
 * shadows a global `Status` inside any class deriving from it - producing a
 * baffling "cannot convert BLECharacteristicCallbacks::Status" error.
 */
enum Presence {
  STATUS_AVAILABLE,
  STATUS_BUSY,
  STATUS_MEETING,
  STATUS_AWAY,
  STATUS_OFF,
  STATUS_COUNT
};

Presence currentStatus = STATUS_OFF;

/*
 * BLE callbacks run on the Bluetooth task, not on the Arduino loop task.
 * Calling FastLED.show() from there while loop() might also be drawing is
 * asking for trouble, so callbacks only ever record intent in these
 * variables and loop() does all the actual drawing.
 */
volatile bool statusPending = false;
volatile Presence pendingStatus = STATUS_OFF;
volatile bool clientConnected = false;

// Animation clock. Driven from loop(), never from a BLE callback.
uint32_t animStart = 0;
bool animating = false;

// ---------------------------------------------------------------------------
// Drawing layer (measured and validated in step 2)
// ---------------------------------------------------------------------------

int XY(int x, int y) {
  if (x < 0 || x >= MATRIX_W || y < 0 || y >= MATRIX_H) {
    return -1;
  }
  int chainRow = (MATRIX_H - 1) - y;                         // flip vertically
  int xInRow = (chainRow % 2 == 0) ? x : (MATRIX_W - 1 - x);  // undo serpentine
  return chainRow * MATRIX_W + xInRow;
}

void setPixel(int x, int y, CRGB colour) {
  int i = XY(x, y);
  if (i >= 0) {
    leds[i] = colour;
  }
}

void drawGlyph(const uint8_t glyph[MATRIX_H], CRGB colour) {
  for (int y = 0; y < MATRIX_H; y++) {
    for (int x = 0; x < MATRIX_W; x++) {
      if ((glyph[y] >> (7 - x)) & 1) {
        setPixel(x, y, colour);
      }
    }
  }
}

// Ease-out: fast at first, gently settling. Written out rather than using
// powf() because it is cheaper and avoids dragging in extra float machinery.
float easeOutCubic(float t) {
  float inv = 1.0f - t;
  return 1.0f - inv * inv * inv;
}

/*
 * Draw a glyph part-way through its reveal.
 *
 * The icon grows outwards from the centre: each pixel gets a start delay
 * proportional to its distance from the middle, so the shape blooms rather
 * than simply fading up as a block.
 *
 * Each pixel also travels from white to its final colour as it fades in, which
 * gives a bright leading edge that settles into the icon colour. That is where
 * the "spark" comes from - a plain fade looks flat by comparison.
 *
 * STAGGER splits the timeline between "waiting to start" and "fading in".
 * At 0.5 the outermost pixel begins half way through and finishes exactly as
 * the animation ends, so every pixel is guaranteed to be fully lit at p = 1.
 */
void drawGlyphProgress(const uint8_t glyph[MATRIX_H], CRGB colour, float p) {
  const float STAGGER = 0.5f;
  const float cx = (MATRIX_W - 1) / 2.0f;
  const float cy = (MATRIX_H - 1) / 2.0f;
  const float maxDist = sqrtf(cx * cx + cy * cy);

  for (int y = 0; y < MATRIX_H; y++) {
    for (int x = 0; x < MATRIX_W; x++) {
      if (!((glyph[y] >> (7 - x)) & 1)) {
        continue;
      }

      float dx = x - cx;
      float dy = y - cy;
      float dist = sqrtf(dx * dx + dy * dy) / maxDist;   // 0 centre .. 1 corner

      float local = (p - dist * STAGGER) / (1.0f - STAGGER);
      if (local <= 0.0f) {
        continue;                     // not started yet
      }
      if (local > 1.0f) {
        local = 1.0f;
      }

      uint8_t a = (uint8_t)(local * 255.0f);
      CRGB c = blend(CRGB::White, colour, a);  // white -> target colour
      c.nscale8_video(a);                      // and fade up from black
      setPixel(x, y, c);
    }
  }
}

// ---------------------------------------------------------------------------
// Status artwork
// ---------------------------------------------------------------------------

/*
 * Full-bleed icons: a single coloured symbol on black, using the whole 8x8.
 *
 * This replaced two earlier attempts, and the progression is worth recording:
 *
 *   1. thin strokes on black      - too small and faint to read
 *   2. coloured disc, white symbol - bright, but the fill drowned the symbol
 *   3. white disc, coloured symbol - same problem, and both states just looked
 *                                    like a white blob from any distance
 *   4. big symbol, no fill        - what we have now
 *
 * The lesson: at 8x8 the SHAPE has to be the icon. A background fill wastes
 * most of the 64 pixels on something carrying no information, and drags the
 * eye away from the few pixels that matter.
 *
 * Strokes are 2 pixels thick wherever possible, because single-pixel lines
 * disappear at a glance. Every glyph touches all four edges.
 */

// Bold check mark, corner to corner.
const uint8_t GLYPH_TICK[MATRIX_H] = {
  0b00000001,
  0b00000011,
  0b00000110,
  0b10001100,
  0b11011000,
  0b01110000,
  0b00110000,
  0b00100000,
};

// Symmetrical X, corner to corner. Tick and cross are the classic opposing
// pair, so they stay distinguishable even when you only catch a glimpse.
const uint8_t GLYPH_CROSS[MATRIX_H] = {
  0b11000011,
  0b01100110,
  0b00111100,
  0b00011000,
  0b00011000,
  0b00111100,
  0b01100110,
  0b11000011,
};

// A monitor with a stand: on a call / in a meeting.
const uint8_t GLYPH_MONITOR[MATRIX_H] = {
  0b11111111,
  0b10000001,
  0b10000001,
  0b10000001,
  0b11111111,
  0b00011000,
  0b00011000,
  0b01111110,
};

/*
 * A 'Z' for away, now edge to edge. This originally replaced a clock face,
 * which was hopeless: a circle with hands needs more pixels than we have.
 */
const uint8_t GLYPH_Z[MATRIX_H] = {
  0b11111111,
  0b00000110,
  0b00001100,
  0b00011000,
  0b00110000,
  0b01100000,
  0b11000000,
  0b11111111,
};

const char* statusName(Presence s) {
  switch (s) {
    case STATUS_AVAILABLE: return "AVAILABLE";
    case STATUS_BUSY:      return "BUSY";
    case STATUS_MEETING:   return "MEETING";
    case STATUS_AWAY:      return "AWAY";
    case STATUS_OFF:       return "OFF";
    default:               return "?";
  }
}

/*
 * Map an incoming command string to a Status.
 * Returns false if the text was not recognised, so we can ignore junk
 * rather than silently displaying the wrong thing.
 */
bool parseStatus(String text, Presence &out) {
  text.trim();
  text.toLowerCase();

  if (text == "available" || text == "0") { out = STATUS_AVAILABLE; return true; }
  if (text == "busy"      || text == "1") { out = STATUS_BUSY;      return true; }
  if (text == "meeting"   || text == "2") { out = STATUS_MEETING;   return true; }
  if (text == "away"      || text == "3") { out = STATUS_AWAY;      return true; }
  if (text == "off"       || text == "4") { out = STATUS_OFF;       return true; }

  return false;
}

/*
 * Which artwork belongs to the current status.
 * Returns false when there is nothing to draw (status off).
 *
 * Pulled out so the reveal and the idle animation cannot drift apart - there
 * is one place that decides what an icon looks like.
 */
bool currentArt(const uint8_t **glyph, CRGB *colour) {
  switch (currentStatus) {
    case STATUS_AVAILABLE: *glyph = GLYPH_TICK;    *colour = CRGB::Green;  return true;
    case STATUS_BUSY:      *glyph = GLYPH_CROSS;   *colour = CRGB::Red;    return true;
    case STATUS_MEETING:   *glyph = GLYPH_MONITOR; *colour = CRGB::Purple; return true;
    case STATUS_AWAY:      *glyph = GLYPH_Z;       *colour = CRGB::Orange; return true;
    default:               return false;
  }
}

/*
 * The settled icon, breathing gently with an occasional sweep of highlight.
 *
 * beatsin8() is FastLED's own oscillator. It is used here in preference to
 * sinf() because it is integer maths and avoids pulling more of the float
 * library into a sketch already sitting at 93% of its flash partition.
 */
void drawGlyphIdle(const uint8_t glyph[MATRIX_H], CRGB colour, uint32_t now) {
  uint8_t breathe = beatsin8(BREATHE_BPM, BREATHE_MIN, 255);

  // The highlight runs on its own cycle: it crosses the panel, then rests.
  uint32_t phase = now % SHIMMER_PERIOD_MS;
  bool sweeping = phase < SHIMMER_SWEEP_MS;

  // Starts just off one corner and ends just off the other, so it enters and
  // leaves cleanly rather than popping into existence mid-glyph.
  float head = sweeping
      ? (-0.25f + (phase / (float)SHIMMER_SWEEP_MS) * 1.5f)
      : -10.0f;    // parked well outside the panel: no highlight at all

  for (int y = 0; y < MATRIX_H; y++) {
    for (int x = 0; x < MATRIX_W; x++) {
      if (!((glyph[y] >> (7 - x)) & 1)) {
        continue;
      }

      CRGB c = colour;
      c.nscale8_video(breathe);

      // Position along the diagonal, 0 at top-left and 1 at bottom-right.
      float u = (x + y) / (float)(MATRIX_W + MATRIX_H - 2);
      float d = u - head;
      if (d < 0) {
        d = -d;
      }
      if (d < SHIMMER_WIDTH) {
        uint8_t g = (uint8_t)((1.0f - d / SHIMMER_WIDTH) * SHIMMER_STRENGTH);
        c = blend(c, CRGB::White, g);
      }

      setPixel(x, y, c);
    }
  }
}

/*
 * Connection indicator: a dim blue dot in the bottom-right corner, shown only
 * when the panel would otherwise be blank. It still distinguishes "nothing
 * connected" from "deliberately off", without punching a hole in the corner of
 * every edge-to-edge icon.
 */
void drawConnectionIndicator() {
  if (!clientConnected && currentStatus == STATUS_OFF) {
    setPixel(MATRIX_W - 1, MATRIX_H - 1, CRGB(0, 0, 30));
  }
}

// One frame of the reveal. p = 0 is nothing drawn, p = 1 is the full icon.
void renderFrame(float p) {
  const uint8_t *glyph;
  CRGB colour;

  FastLED.clear();
  if (currentArt(&glyph, &colour)) {
    drawGlyphProgress(glyph, colour, easeOutCubic(p));
  }
  drawConnectionIndicator();
  FastLED.show();
}

// One frame of the settled, continuously animating icon.
void renderIdle() {
  const uint8_t *glyph;
  CRGB colour;

  FastLED.clear();
  if (currentArt(&glyph, &colour)) {
    drawGlyphIdle(glyph, colour, millis());
  }
  drawConnectionIndicator();
  FastLED.show();
}

void renderStatus() {
  renderIdle();
}

void startAnimation() {
  animStart = millis();
  animating = true;
}

// ---------------------------------------------------------------------------
// BLE
// ---------------------------------------------------------------------------

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    clientConnected = true;
    Serial.println("BLE: client connected");
  }

  void onDisconnect(BLEServer *server) override {
    clientConnected = false;
    Serial.println("BLE: client disconnected, advertising again");
    // Without this the device becomes invisible after the first disconnect.
    server->startAdvertising();
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) override {
    String value = characteristic->getValue();

    Serial.print("BLE: received \"");
    Serial.print(value);
    Serial.println("\"");

    Presence parsed;
    if (parseStatus(value, parsed)) {
      pendingStatus = parsed;
      statusPending = true;
    } else {
      Serial.println("BLE: unrecognised command, ignoring");
    }
  }
};

void setupBLE() {
  BLEDevice::init(DEVICE_NAME);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  BLECharacteristic *rx = service->createCharacteristic(
    CHAR_RX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_READ
  );
  rx->setCallbacks(new RxCallbacks());
  rx->setValue("off");

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.print("BLE: advertising as \"");
  Serial.print(DEVICE_NAME);
  Serial.println("\"");
}

// ---------------------------------------------------------------------------

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("glowgrid: BLE status display");

  FastLED.addLeds<WS2812B, DATA_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(BRIGHTNESS);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, MAX_MILLIAMPS);
  FastLED.clear(true);

  setupBLE();

  renderStatus();
}

void loop() {
  if (statusPending) {
    statusPending = false;
    currentStatus = pendingStatus;
    Serial.print("status -> ");
    Serial.println(statusName(currentStatus));
    startAnimation();
  }

  /*
   * Frames are stepped here rather than run in blocking loops, so the
   * Bluetooth task keeps getting serviced and a status sent mid-animation is
   * picked up promptly.
   *
   * The panel is now redrawn every frame forever, which also means the
   * connection indicator no longer needs its own change detection - it is
   * simply drawn, or not, as part of each frame.
   */
  if (animating) {
    uint32_t elapsed = millis() - animStart;
    if (elapsed >= ANIM_MS) {
      animating = false;      // reveal finished, idle animation takes over
      renderIdle();
    } else {
      renderFrame(elapsed / (float)ANIM_MS);
    }
    delay(16);                // ~60 fps during the reveal
  } else {
    renderIdle();
    delay(IDLE_FRAME_MS);     // ~40 fps once settled
  }
}
