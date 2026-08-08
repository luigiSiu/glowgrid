import Foundation
import CoreBluetooth

/*
 * Talks to the glowgrid panel over Bluetooth Low Energy.
 *
 * Unlike the Python CLI, which connects, writes and disconnects for every
 * change, this holds the connection open for as long as the app runs. A status
 * change is then effectively instant instead of ~1.5s, and the menu can show
 * whether the panel is actually reachable.
 *
 * CoreBluetooth delegate callbacks arrive on a background queue, so published
 * properties are bounced onto the main actor before SwiftUI sees them.
 */

let glowgridServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
let glowgridRxUUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
let glowgridDeviceName  = "glowgrid"

enum ConnectionState: Equatable {
    case bluetoothOff
    case unauthorised
    case searching
    case connecting
    case connected
    case disconnected

    var description: String {
        switch self {
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorised: return "Bluetooth permission denied"
        case .searching:    return "Searching for a panel…"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}

/// A panel seen while scanning.
struct DiscoveredPanel: Identifiable, Equatable {
    let id: UUID          // CoreBluetooth identifier: stable per Mac, not a MAC address
    let name: String
}

@MainActor
final class BLEClient: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .searching
    @Published private(set) var panels: [DiscoveredPanel] = []
    @Published private(set) var connectedPanelID: UUID?

    /// Brightness as last reported by the panel itself.
    @Published private(set) var reportedBrightness: Int?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?

    /*
     * Which panel the user chose, remembered across launches. Without this the
     * app grabs whichever panel answers first, which is wrong as soon as there
     * is more than one in range.
     */
    private let preferredKey = "preferredPanelID"

    private var preferredPanelID: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: preferredKey) else { return nil }
            return UUID(uuidString: s)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: preferredKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredKey)
            }
        }
    }

    var hasPreferredPanel: Bool { preferredPanelID != nil }

    /*
     * Commands requested before the characteristic is ready are queued rather
     * than dropped. Discovery takes a moment at launch, so without this the
     * first thing you do after opening the app would silently vanish.
     */
    private var pending: [String] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func send(_ status: Status) {
        send(command: status.rawValue)
    }

    func setBrightness(_ value: Int) {
        send(command: "b:\(value)")
    }

    func stepBrightness(up: Bool) {
        send(command: up ? "b+" : "b-")
    }

    func showText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(command: "t:\(trimmed)")
    }

    func clearText() {
        send(command: "clear")
    }

    /// Longest message the panel will accept, bounded by the negotiated MTU.
    var maxTextLength: Int {
        guard let peripheral else { return 20 }
        return max(1, peripheral.maximumWriteValueLength(for: .withResponse) - 2)  // less "t:"
    }

    func selectPanel(_ id: UUID) {
        preferredPanelID = id
        guard id != connectedPanelID else { return }

        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        connectTo(id: id)
    }

    func forgetPanel() {
        preferredPanelID = nil
    }

    // MARK: - Internals

    private func send(command: String) {
        guard let peripheral, let rx, state == .connected else {
            pending.append(command)
            return
        }
        write(command, to: peripheral, characteristic: rx)
    }

    private func write(_ command: String, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let data = command.data(using: .utf8) else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)

        // Ask the panel what its state is now, so the menu shows real
        // brightness rather than a guess that drifts when the CLI is used.
        peripheral.readValue(for: characteristic)
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        state = .searching

        /*
         * Filtered by service UUID rather than name: macOS can report a
         * peripheral before its name resolves, so name matching intermittently
         * misses the panel on the first pass.
         */
        central.scanForPeripherals(withServices: [glowgridServiceUUID])
    }

    private func connectTo(id: UUID) {
        guard let known = central.retrievePeripherals(withIdentifiers: [id]).first else {
            startScan()
            return
        }
        peripheral = known
        known.delegate = self
        state = .connecting
        central.connect(known)
    }

    /// Parse "status=busy brightness=10 mode=status".
    private func parseReportedState(_ text: String) {
        for field in text.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0] == "brightness" {
                reportedBrightness = Int(parts[1])
            }
        }
    }
}

extension BLEClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                // Go straight back to the remembered panel if there is one.
                if let preferred = preferredPanelID {
                    connectTo(id: preferred)
                }
                startScan()
            case .unauthorized:
                state = .unauthorised
            case .poweredOff:
                state = .bluetoothOff
            default:
                state = .disconnected
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? glowgridDeviceName

        Task { @MainActor in
            if !panels.contains(where: { $0.id == id }) {
                panels.append(DiscoveredPanel(id: id, name: name))
            }

            /*
             * Connect if this is the remembered panel, or if nothing is
             * remembered and we have not connected to anything yet. The second
             * case keeps a fresh install working with no configuration.
             */
            let shouldConnect = (preferredPanelID == id)
                || (preferredPanelID == nil && self.peripheral == nil)

            guard shouldConnect else { return }

            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedPanelID = peripheral.identifier
            peripheral.discoverServices([glowgridServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            rx = nil
            connectedPanelID = nil
            state = .disconnected
            startScan()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            state = .disconnected
            startScan()
        }
    }
}

extension BLEClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let service = peripheral.services?.first(where: { $0.uuid == glowgridServiceUUID }) else {
                return
            }
            peripheral.discoverCharacteristics([glowgridRxUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == glowgridRxUUID }) else {
                return
            }

            rx = characteristic
            state = .connected

            // Learn the panel's actual brightness instead of assuming a value.
            peripheral.readValue(for: characteristic)

            let queued = pending
            pending.removeAll()
            for command in queued {
                write(command, to: peripheral, characteristic: characteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let text = characteristic.value.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            guard let text else { return }
            parseReportedState(text)
        }
    }
}
