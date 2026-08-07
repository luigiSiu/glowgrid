/*
 * glowgrid - step 1: first light on the matrix
 *
 * Panel: BTF-LIGHTING WS2812B ECO, 8x8 = 64 pixels, DC5V, colour order GRB
 * Board: ESP32 Dev Module (esp32:esp32:esp32)
 *
 * Wiring (use the connector labelled DIN, NOT DOUT):
 *   ESP32 VIN  -> panel 5V
 *   ESP32 GND  -> panel GND
 *   ESP32 D13  -> panel DIN     (D13 silkscreen == GPIO13)
 *
 * This sketch is deliberately timid. It never lights more than a handful of
 * LEDs and it tells FastLED to enforce a hard current budget, so it cannot
 * pull more than USB can deliver. Full white on all 64 pixels would want
 * ~3.8 A; USB gives you ~0.5 A. Do not raise BRIGHTNESS until the panel has
 * its own 5V supply.
 */

#include <FastLED.h>

#define DATA_PIN    13
#define NUM_LEDS    64
#define MATRIX_W    8
#define MATRIX_H    8

// Keep this low while running from USB power. 15/255 is plenty to see.
#define BRIGHTNESS  15

// Hard ceiling in milliamps. FastLED auto-dims to stay under this.
// Leave headroom for the ESP32 itself, which needs ~150-200 mA.
#define MAX_MILLIAMPS 300

CRGB leds[NUM_LEDS];

void setup() {
  Serial.begin(115200);
  delay(500);
  Serial.println();
  Serial.println("glowgrid: matrix test starting");

  FastLED.addLeds<WS2812B, DATA_PIN, GRB>(leds, NUM_LEDS);
  FastLED.setBrightness(BRIGHTNESS);
  FastLED.setMaxPowerInVoltsAndMilliamps(5, MAX_MILLIAMPS);

  FastLED.clear(true);   // start with everything off
  delay(500);
}

// Test 1: walk a single white dot through all 64 LEDs, in chain order.
// This proves the data line works and shows you the physical wiring order.
void walkSingleDot() {
  Serial.println("test: single dot walk");
  for (int i = 0; i < NUM_LEDS; i++) {
    FastLED.clear();
    leds[i] = CRGB::White;
    FastLED.show();
    delay(60);
  }
  FastLED.clear(true);
  delay(300);
}

// Test 2: light pixel 0 red, then green, then blue.
// If the colours come out in the wrong order, the GRB setting above is wrong.
void checkColourOrder() {
  Serial.println("test: colour order (expect red, then green, then blue)");

  const CRGB colours[3] = { CRGB::Red, CRGB::Green, CRGB::Blue };
  const char* names[3]  = { "red", "green", "blue" };

  for (int c = 0; c < 3; c++) {
    FastLED.clear();
    leds[0] = colours[c];
    FastLED.show();
    Serial.print("  showing ");
    Serial.println(names[c]);
    delay(1000);
  }
  FastLED.clear(true);
  delay(300);
}

void loop() {
  walkSingleDot();
  checkColourOrder();
}
