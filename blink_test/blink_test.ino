/*
 * glowgrid - step 0: prove the board works
 *
 * Board: ESP32 Dev Module (ESP32-WROOM-32)
 * FQBN:  esp32:esp32:esp32
 *
 * Do NOT wire the LED matrix yet. This sketch only blinks the small LED
 * that is already soldered onto the ESP32 board. If this blinks, it means:
 *   - the CH340 USB chip is talking to your Mac
 *   - the toolchain compiles and uploads correctly
 *   - the board is not dead
 *
 * Once this works, move on to the matrix (see README.md).
 */

// On most ESP32-WROOM-32 dev boards the onboard blue LED is on GPIO 2.
// If nothing blinks, try 13 or 5 - it varies between clones.
const int ONBOARD_LED = 2;

void setup() {
  Serial.begin(115200);
  delay(500);          // give the USB serial a moment to come up
  Serial.println();
  Serial.println("glowgrid: board is alive");

  pinMode(ONBOARD_LED, OUTPUT);
}

void loop() {
  digitalWrite(ONBOARD_LED, HIGH);
  Serial.println("on");
  delay(500);

  digitalWrite(ONBOARD_LED, LOW);
  Serial.println("off");
  delay(500);
}
