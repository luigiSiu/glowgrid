/*
 * glowgrid - step 2b: the drawing layer
 *
 * Measured physical layout of this panel (BTF-LIGHTING WS2812B 8x8):
 *   - chain index 0 is the BOTTOM-LEFT corner
 *   - the chain runs in horizontal rows of 8
 *   - the bottom row runs LEFT -> RIGHT
 *   - each row above it reverses direction (serpentine)
 *
 * Panel reference orientation: LED-side towards you, wires exiting the
 * BOTTOM-LEFT corner.
 *
 * The coordinate system we expose to the rest of the code is the normal
 * screen convention, because that is how bitmaps and fonts are written:
 *
 *     (0,0) --------- (7,0)      x increases to the RIGHT
 *       |               |        y increases DOWNWARD
 *       |               |
 *     (0,7) --------- (7,7)
 *
 * So XY() has to do two things: flip vertically (because index 0 is at the
 * bottom, not the top) and reverse alternate rows (serpentine).
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
 * Translate screen coordinates (x right, y down, origin top-left) into a
 * position in the physical LED chain.
 *
 * Returns -1 for out-of-bounds coordinates so callers can safely clip
 * instead of corrupting memory.
 */
int XY(int x, int y) {
  if (x < 0 || x >= MATRIX_W || y < 0 || y >= MATRIX_H) {
    return -1;
  }

  // Chain rows are numbered from the bottom, screen rows from the top.
  int chainRow = (MATRIX_H - 1) - y;

  // Even chain rows run left->right, odd ones right->left.
  int xInRow = (chainRow % 2 == 0) ? x : (MATRIX_W - 1 - x);

  return chainRow * MATRIX_W + xInRow;
}

// Safe single pixel write in screen coordinates.
void setPixel(int x, int y, CRGB colour) {
  int i = XY(x, y);
  if (i >= 0) {
    leds[i] = colour;
  }
}

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("glowgrid: XY drawing layer test");

  FastLED.addLeds<WS2812B, DATA_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(BRIGHTNESS);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, MAX_MILLIAMPS);
  FastLED.clear(true);
  delay(1000);
}

/*
 * An 'F' is the ideal validation glyph: it is asymmetric both horizontally
 * and vertically, so a mirrored or rotated mapping is immediately obvious.
 * A square or a cross would look correct even if the mapping were wrong.
 *
 * Bit 7 (the leftmost bit as written) is x=0. Row 0 as written is the top.
 */
const uint8_t GLYPH_F[MATRIX_H] = {
  0b01111110,
  0b01100000,
  0b01100000,
  0b01111100,
  0b01100000,
  0b01100000,
  0b01100000,
  0b00000000,
};

void drawGlyph(const uint8_t glyph[MATRIX_H], CRGB colour) {
  for (int y = 0; y < MATRIX_H; y++) {
    for (int x = 0; x < MATRIX_W; x++) {
      bool on = (glyph[y] >> (7 - x)) & 1;
      if (on) {
        setPixel(x, y, colour);
      }
    }
  }
}

void hold(const char* label, int ms) {
  Serial.print("showing: ");
  Serial.println(label);
  FastLED.show();
  delay(ms);
  FastLED.clear(true);
  delay(700);
}

void loop() {
  // Test 1: a letter F. Must read as a correct, upright, unmirrored F.
  FastLED.clear();
  drawGlyph(GLYPH_F, CRGB::White);
  hold("letter F in white - should be upright and NOT mirrored", 4000);

  // Test 2: the top row only. Proves y=0 really is the top.
  FastLED.clear();
  for (int x = 0; x < MATRIX_W; x++) {
    setPixel(x, 0, CRGB::Green);
  }
  hold("row y=0 in green - should be the TOP row", 2500);

  // Test 3: the left column only. Proves x=0 really is the left.
  FastLED.clear();
  for (int y = 0; y < MATRIX_H; y++) {
    setPixel(0, y, CRGB::Blue);
  }
  hold("column x=0 in blue - should be the LEFT column", 2500);

  // Test 4: the origin pixel on its own. Should be the top-left corner.
  FastLED.clear();
  setPixel(0, 0, CRGB::Red);
  hold("pixel (0,0) in red - should be the TOP-LEFT corner", 2500);

  Serial.println("--- cycle complete ---");
  delay(800);
}
