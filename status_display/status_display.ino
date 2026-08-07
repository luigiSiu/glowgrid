/*
 * glowgrid - step 3: the availability status display
 *
 * This is the real goal: an 8x8 panel showing whether you are available.
 * For now the states cycle on a timer so we can check the artwork reads
 * clearly from across a room. No Bluetooth yet - deliberately.
 *
 * The structure matters more than the timer. Everything goes through:
 *
 *     setStatus(Status)   - change what should be shown
 *     renderStatus()      - draw the current status to the panel
 *
 * When we add BLE in the next step, the ONLY change is that incoming
 * Bluetooth messages call setStatus() instead of the timer in loop().
 * Nothing else here needs to move.
 *
 * Layout, measured in step 2: index 0 bottom-left, horizontal rows,
 * serpentine, bottom row left->right. XY() hides all of that.
 */

#include <FastLED.h>

#define DATA_PIN    13
#define NUM_LEDS    64
#define MATRIX_W    8
#define MATRIX_H    8

#define BRIGHTNESS  15
#define MAX_MILLIAMPS 300

CRGB leds[NUM_LEDS];

/*
 * This enum MUST be declared before any function that mentions it.
 *
 * The Arduino build step auto-generates prototypes for your functions and
 * injects them just above the first function definition in the file. If the
 * enum were declared further down, those generated prototypes would reference
 * a type that does not exist yet and the build fails with a confusing
 * "'Status' was not declared in this scope".
 */
enum Status {
  STATUS_AVAILABLE,
  STATUS_BUSY,
  STATUS_MEETING,
  STATUS_AWAY,
  STATUS_OFF,
  STATUS_COUNT
};

Status currentStatus = STATUS_AVAILABLE;

// ---------------------------------------------------------------------------
// Drawing layer (validated in step 2b)
// ---------------------------------------------------------------------------

int XY(int x, int y) {
  if (x < 0 || x >= MATRIX_W || y < 0 || y >= MATRIX_H) {
    return -1;
  }
  int chainRow = (MATRIX_H - 1) - y;                       // flip vertically
  int xInRow = (chainRow % 2 == 0) ? x : (MATRIX_W - 1 - x); // undo serpentine
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

// ---------------------------------------------------------------------------
// Status artwork
//
// At 8x8 the only things that read clearly from a distance are bold shapes
// plus a strong colour. Detail is wasted here, so each icon is deliberately
// crude and relies on colour to carry most of the meaning.
// ---------------------------------------------------------------------------

// Tick mark, rising to the right.
const uint8_t GLYPH_TICK[MATRIX_H] = {
  0b00000000,
  0b00000001,
  0b00000010,
  0b00000100,
  0b10001000,
  0b01010000,
  0b00100000,
  0b00000000,
};

// Two solid bars: the universal "do not disturb".
const uint8_t GLYPH_BAR[MATRIX_H] = {
  0b00000000,
  0b00000000,
  0b00000000,
  0b11111111,
  0b11111111,
  0b00000000,
  0b00000000,
  0b00000000,
};

// A monitor on a stand: on a call / in a meeting.
const uint8_t GLYPH_SCREEN[MATRIX_H] = {
  0b00000000,
  0b01111110,
  0b01000010,
  0b01000010,
  0b01000010,
  0b01111110,
  0b00011000,
  0b00111100,
};

/*
 * A 'Z' for away. This replaced a clock face, which was unreadable: a circle
 * with hands inside it needs more than the 6x6 pixels available, so it just
 * looked like an orange blob. A letter fills the grid and reads instantly.
 */
const uint8_t GLYPH_Z[MATRIX_H] = {
  0b00000000,
  0b01111110,
  0b00000100,
  0b00001000,
  0b00010000,
  0b00100000,
  0b01111110,
  0b00000000,
};

const char* statusName(Status s) {
  switch (s) {
    case STATUS_AVAILABLE: return "AVAILABLE";
    case STATUS_BUSY:      return "BUSY";
    case STATUS_MEETING:   return "MEETING";
    case STATUS_AWAY:      return "AWAY";
    case STATUS_OFF:       return "OFF";
    default:               return "?";
  }
}

void setStatus(Status s) {
  if (s != currentStatus) {
    currentStatus = s;
    Serial.print("status -> ");
    Serial.println(statusName(s));
  }
}

void renderStatus() {
  FastLED.clear();

  switch (currentStatus) {
    case STATUS_AVAILABLE:
      drawGlyph(GLYPH_TICK, CRGB::Green);
      break;
    case STATUS_BUSY:
      drawGlyph(GLYPH_BAR, CRGB::Red);
      break;
    case STATUS_MEETING:
      drawGlyph(GLYPH_SCREEN, CRGB::Purple);
      break;
    case STATUS_AWAY:
      drawGlyph(GLYPH_Z, CRGB::Orange);
      break;
    case STATUS_OFF:
    default:
      // leave the panel blank
      break;
  }

  FastLED.show();
}

// ---------------------------------------------------------------------------

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("glowgrid: status display");
  Serial.println("cycling through all states so the artwork can be reviewed");

  FastLED.addLeds<WS2812B, DATA_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(BRIGHTNESS);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, MAX_MILLIAMPS);
  FastLED.clear(true);
  delay(500);
}

void loop() {
  // Temporary driver. BLE replaces this in the next step.
  for (int s = 0; s < STATUS_COUNT; s++) {
    setStatus((Status)s);
    renderStatus();
    delay(3000);
  }
}
