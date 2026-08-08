import SwiftUI

/*
 * Menu bar entry point.
 *
 * MenuBarExtra needs macOS 13+, which is why Info.plist sets
 * LSMinimumSystemVersion to 13.0. Combined with LSUIElement, the app has no
 * Dock icon, no window and no app switcher entry - it is only the menu.
 */
@main
struct GlowgridApp: App {
    @StateObject private var ble: BLEClient
    @StateObject private var controller: StatusController

    init() {
        // One client, shared by the menu (for connection state) and the
        // controller (for sending). Declared without an inline initialiser so
        // it is not built twice.
        let client = BLEClient()
        _ble = StateObject(wrappedValue: client)
        _controller = StateObject(wrappedValue: StatusController(ble: client))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(ble: ble, controller: controller)
        } label: {
            // The menu bar icon reflects the current status at a glance.
            Image(systemName: controller.status.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @ObservedObject var ble: BLEClient
    @ObservedObject var controller: StatusController

    var body: some View {
        // Connection state, so a dead link is visible without staring at the
        // panel wondering why nothing changes.
        Text(ble.state.description)

        Divider()

        ForEach(Status.allCases) { status in
            Button {
                controller.selectManual(status)
            } label: {
                // A tick marks the active status, but only in manual mode -
                // otherwise it would look like you had chosen it by hand.
                if controller.mode == .manual && controller.status == status {
                    Text("✓ \(status.title)")
                } else {
                    Text(status.title)
                }
            }
        }

        Divider()

        Button {
            controller.enableAutomatic()
        } label: {
            if controller.mode == .automatic {
                Text("✓ Automatic (camera / mic)")
            } else {
                Text("Automatic (camera / mic)")
            }
        }

        if controller.mode == .automatic {
            Text("Showing: \(controller.status.title)")
        }

        Divider()

        Button("Quit Glowgrid") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
