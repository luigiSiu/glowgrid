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

    var isConnected: Bool { state == .connected }

    /*
     * Called once the panel is connected and writable, including after a
     * reconnection.
     *
     * This exists because the panel forgets its status when it loses power: it
     * boots showing nothing, while the app still believes it is showing
     * whatever you last chose. Somebody has to resolve that disagreement, and
     * the app is the one that knows the answer - so it pushes the status again
     * from here. Without it, a power cycle leaves the panel dark until you
     * pick a status by hand, which is exactly the bug this replaces.
     */
    var onConnected: (() -> Void)?

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

    /*
     * Look for panels again.
     *
     * Needed because scanning is deliberately stopped once connected, so the
     * picker would otherwise never learn about a panel switched on later.
     */
    func rescan() {
        panels.removeAll()

        // Keep the one we are talking to in the list, or it would vanish from
        // the picker until the scan happened to see it again.
        if let peripheral, state == .connected {
            panels.append(DiscoveredPanel(
                id: peripheral.identifier,
                name: peripheral.name ?? glowgridDeviceName
            ))
        }

        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [glowgridServiceUUID])

        // Time-boxed. Scanning indefinitely while connected is what caused the
        // flapping described in startScan(), so it must not be left running.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if state == .connected {
                central.stopScan()
            }
        }
    }

    // MARK: - Internals

    private func send(command: String) {
        /*
         * Dropped, not queued, when there is nothing to write to.
         *
         * Queueing was worse than it sounds. Ten impatient taps on brightness
         * while the panel was unplugged would all arrive at once on
         * reconnection and send it lurching, and a status queued behind them
         * could be applied out of order. Statuses do not need a queue anyway:
         * onConnected re-sends the current one, so intent survives the outage
         * without replaying the individual clicks that expressed it.
         */
        guard let peripheral, let rx, state == .connected else { return }
        write(command, to: peripheral, characteristic: rx)
    }

    private func write(_ command: String, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let data = command.data(using: .utf8) else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)

        // Ask the panel what its state is now, so the menu shows real
        // brightness rather than a guess that drifts when the CLI is used.
        peripheral.readValue(for: characteristic)
    }

    /*
     * Scan for panels. Only ever while NOT connected.
     *
     * Leaving the scanner running after connecting caused a genuine
     * connect/disconnect loop, visible as the panel blinking and the menu
     * flicking between Connected and Searching several times a second. The
     * mechanism: the firmware deliberately keeps advertising while connected,
     * so our own panel reappears in every scan result, and each result drove
     * another connect attempt on a peripheral that was already connected. Each
     * resulting reconnect re-sent the status, which restarted the reveal
     * animation - hence the blinking.
     *
     * So: scan while looking, stop once found.
     */
    private func startScan() {
        guard central.state == .poweredOn else { return }

        // Guarded because startScan() is also reached from paths that can run
        // while a link is up, and clobbering the state would lie to the menu.
        if state != .connected {
            state = .searching
        }

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

            /*
             * Do not stack connect requests. A peripheral that is already
             * connected, or has a connect request in flight, is not
             * .disconnected - and issuing another attempt for it is what turned
             * a still-advertising panel into a connect/disconnect loop.
             */
            guard peripheral.state == .disconnected else { return }

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

            // Stale the moment the link drops, and misleading if left on
            // screen: an unplugged panel has no brightness.
            reportedBrightness = nil

            /*
             * Ask to connect again straight away.
             *
             * A connect request outlives the peripheral going away -
             * CoreBluetooth simply completes it whenever the device comes
             * back - which is precisely the behaviour wanted for a panel that
             * gets unplugged or power cycled.
             *
             * This is also where reconnection was broken before. The old code
             * only rescanned, and the scan handler ignored anything already
             * held in `self.peripheral`, which is never cleared. So unless the
             * user had explicitly chosen a panel, the app would sit at
             * "Searching" forever after the first disconnect and never come
             * back on its own.
             */
            state = .searching
            central.connect(peripheral)

            // Keep scanning as well, so the picker still notices other panels.
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

            // Tracked so onConnected fires on a real transition only. Were it
            // to run again on an already-live link, it would re-send the status
            // and restart the reveal animation for no reason.
            let wasConnected = (state == .connected)

            rx = characteristic
            state = .connected

            // Nothing left to look for, and continuing to scan while connected
            // provokes repeated connect attempts. See startScan().
            central.stopScan()

            // Learn the panel's actual brightness instead of assuming a value.
            peripheral.readValue(for: characteristic)

            // Let the controller restore what the panel should be showing. The
            // panel boots blank after a power cycle and cannot know.
            if !wasConnected {
                onConnected?()
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
