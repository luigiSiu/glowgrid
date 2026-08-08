import Foundation
import CoreBluetooth

/*
 * Talks to the glowgrid panel over Bluetooth Low Energy.
 *
 * Unlike the Python CLI, which connects, writes and disconnects for every
 * single change, this holds the connection open for as long as the app runs.
 * That makes a status change effectively instant instead of ~1.5s, and lets
 * the menu show whether the panel is actually reachable.
 *
 * Everything here is driven by CoreBluetooth delegate callbacks, which arrive
 * on a background queue. Published properties are therefore bounced onto the
 * main actor before SwiftUI sees them.
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
        case .searching:    return "Searching for panel…"
        case .connecting:   return "Connecting…"
        case .connected:    return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}

@MainActor
final class BLEClient: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .searching

    private var central: CBCentralManager!
    private var panel: CBPeripheral?
    private var rx: CBCharacteristic?

    /*
     * If a write is requested before the characteristic is ready - which is
     * common at launch, since discovery takes a moment - remember it and send
     * it as soon as we are connected. Without this, the first status set after
     * opening the app would silently vanish.
     */
    private var pendingStatus: Status?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func send(_ status: Status) {
        guard let panel, let rx, state == .connected else {
            pendingStatus = status
            return
        }
        write(status, to: panel, characteristic: rx)
    }

    private func write(_ status: Status, to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let data = status.rawValue.data(using: .utf8) else { return }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        state = .searching

        /*
         * Scanning filtered by service UUID rather than by name. macOS can
         * return peripherals whose name is not yet resolved, so matching on
         * name alone intermittently misses the device on the first pass.
         */
        central.scanForPeripherals(withServices: [glowgridServiceUUID])
    }
}

extension BLEClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
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
        Task { @MainActor in
            central.stopScan()
            self.panel = peripheral
            peripheral.delegate = self
            state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.discoverServices([glowgridServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            rx = nil
            state = .disconnected
            // The panel may simply have been unplugged; keep looking for it.
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

            // Flush anything requested while we were still connecting.
            if let pending = pendingStatus {
                pendingStatus = nil
                write(pending, to: peripheral, characteristic: characteristic)
            }
        }
    }
}
