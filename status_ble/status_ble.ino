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

#define BRIGHTNESS  15
#define MAX_MILLIAMPS 300

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

// ---------------------------------------------------------------------------
// Status artwork
// ---------------------------------------------------------------------------

const uint8_t GLYPH_TICK[MATRIX_H] = {
  0b00000000, 0b00000001, 0b00000010, 0b00000100,
  0b10001000, 0b01010000, 0b00100000, 0b00000000,
};

const uint8_t GLYPH_BAR[MATRIX_H] = {
  0b00000000, 0b00000000, 0b00000000, 0b11111111,
  0b11111111, 0b00000000, 0b00000000, 0b00000000,
};

const uint8_t GLYPH_SCREEN[MATRIX_H] = {
  0b00000000, 0b01111110, 0b01000010, 0b01000010,
  0b01000010, 0b01111110, 0b00011000, 0b00111100,
};

/*
 * A 'Z' for away. This replaced a clock face, which was unreadable: a circle
 * with hands inside it needs more than the 6x6 pixels available, so it just
 * looked like an orange blob. A letter fills the grid and reads instantly.
 */
const uint8_t GLYPH_Z[MATRIX_H] = {
  0b00000000, 0b01111110, 0b00000100, 0b00001000,
  0b00010000, 0b00100000, 0b01111110, 0b00000000,
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

void renderStatus() {
  FastLED.clear();

  switch (currentStatus) {
    case STATUS_AVAILABLE: drawGlyph(GLYPH_TICK,   CRGB::Green);  break;
    case STATUS_BUSY:      drawGlyph(GLYPH_BAR,    CRGB::Red);    break;
    case STATUS_MEETING:   drawGlyph(GLYPH_SCREEN, CRGB::Purple); break;
    case STATUS_AWAY:      drawGlyph(GLYPH_Z,      CRGB::Orange); break;
    case STATUS_OFF:
    default:
      break;
  }

  /*
   * Connection indicator: a dim blue dot in the bottom-right corner while
   * nothing is connected. Without this, "no client" and "status off" look
   * identical, which makes debugging the Mac side much harder.
   */
  if (!clientConnected) {
    setPixel(MATRIX_W - 1, MATRIX_H - 1, CRGB(0, 0, 30));
  }

  FastLED.show();
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
  static bool lastConnected = false;

  if (statusPending) {
    statusPending = false;
    currentStatus = pendingStatus;
    Serial.print("status -> ");
    Serial.println(statusName(currentStatus));
    renderStatus();
  }

  // Redraw when the connection indicator needs to appear or disappear.
  if (clientConnected != lastConnected) {
    lastConnected = clientConnected;
    renderStatus();
  }

  delay(50);
}
