/*
 * glowgrid - step 2a: work out the physical layout
 *
 * Before we can draw shapes we need to know how LED chain index maps to
 * (column, row) on the physical panel. That varies by manufacturer, so we
 * measure it instead of guessing.
 *
 * HOW TO READ THIS TEST
 *
 * Hold the panel LED-side towards you, with the DIN/5V/GND wires coming out
 * of the BOTTOM LEFT corner. Keep it in that orientation for the whole test.
 * Then watch the two phases and note what you see:
 *
 *   Phase 1 - RED, one single pixel.
 *             This is chain index 0. Which corner is it in?
 *
 *   Phase 2 - a BRIGHT WHITE pixel walks slowly through chain indices 0..15,
 *             one step every 400 ms, leaving a DIM RED trail behind it.
 *             Watch the path. You are looking for:
 *               - where it starts
 *               - which way it travels along the first row
 *               - whether the second row doubles back in the opposite
 *                 direction (serpentine) or restarts from the same side
 *                 (progressive)
 *
 * The earlier calibration lit full rows at once, which proved the rows but
 * made direction impossible to read. This version fixes that.
 */

#include <FastLED.h>

#define DATA_PIN    13
#define NUM_LEDS    64
#define BRIGHTNESS  15
#define MAX_MILLIAMPS 300

CRGB leds[NUM_LEDS];

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("glowgrid: XY calibration");
  Serial.println("Hold panel LED-side up, DIN wires at the BOTTOM edge.");

  FastLED.addLeds<WS2812B, DATA_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(BRIGHTNESS);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, MAX_MILLIAMPS);
  FastLED.clear(true);
  delay(1000);
}

void showStartCorner() {
  Serial.println("phase 1: RED single pixel = chain index 0");

  FastLED.clear();
  leds[0] = CRGB::Red;
  FastLED.show();
  delay(3000);

  FastLED.clear(true);
  delay(800);
}

void walkFirstTwoRows() {
  Serial.println("phase 2: WHITE pixel walks indices 0..15, dim red trail behind it");

  FastLED.clear();
  for (int i = 0; i < 16; i++) {
    if (i > 0) {
      leds[i - 1] = CRGB(40, 0, 0);
    }
    leds[i] = CRGB::White;
    FastLED.show();

    Serial.print("  index ");
    Serial.println(i);
    delay(400);
  }

  delay(2500);
  FastLED.clear(true);
  delay(1000);
}

void loop() {
  showStartCorner();
  walkFirstTwoRows();

  Serial.println("--- cycle complete, repeating ---");
  delay(1200);
}
