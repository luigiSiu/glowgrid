import SwiftUI

/*
 * Menu bar entry point.
 *
 * MenuBarExtra needs macOS 13+, which is why Info.plist sets
 * LSMinimumSystemVersion to 13.0. Combined with LSUIElement, the app has no
 * Dock icon, no window and no app switcher entry - it is only the menu.
 *
 * The style is .window rather than .menu. A .menu MenuBarExtra is rendered by
 * AppKit as a real NSMenu, which can only hold menu items: a TextField placed
 * in one simply does not appear. Sending a message to the panel needs text
 * input, so the whole thing is a small panel instead.
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
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var ble: BLEClient
    @ObservedObject var controller: StatusController

    @State private var message: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusSection
            Divider()
            brightnessSection
            Divider()
            messageSection
            Divider()
            panelSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 260)
        .onAppear {
            /*
             * LSUIElement apps are "accessory" apps and are not active, so the
             * panel's window cannot become key - which means the text field
             * silently refuses to accept typing. Activating on open fixes it.
             */
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Sections

    /// Connection state, so a dead link is visible without staring at the
    /// panel wondering why nothing changes.
    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ble.state == .connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(ble.state.description)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Status.allCases) { status in
                // A tick marks the active status, but only in manual mode -
                // otherwise it would look like you had chosen it by hand.
                row(title: status.title,
                    ticked: controller.mode == .manual && controller.status == status) {
                    controller.selectManual(status)
                }
            }

            row(title: "Automatic (camera / mic)",
                ticked: controller.mode == .automatic) {
                controller.enableAutomatic()
            }

            if controller.mode == .automatic {
                Text("Showing: \(controller.status.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private var brightnessSection: some View {
        HStack {
            Text("Brightness")
                .font(.system(size: 12))

            Spacer()

            // The value comes from the panel itself, read back after every
            // write, so it stays right even when the CLI changes it.
            Text(ble.reportedBrightness.map(String.init) ?? "–")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 20)

            Button {
                ble.stepBrightness(up: false)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.bordered)

            Button {
                ble.stepBrightness(up: true)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Scroll a message…", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(sendMessage)

                Button("Send", action: sendMessage)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                // The font has no lowercase, so the firmware upper-cases
                // everything. Saying so up front avoids surprise.
                Text("Shown in capitals, max \(ble.maxTextLength) characters")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear") {
                    message = ""
                    ble.clearText()
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
            }
        }
    }

    private var panelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Picking a panel matters as soon as there is more than one in
            // range: otherwise the app talks to whichever answers first.
            Menu(currentPanelName) {
                if ble.panels.isEmpty {
                    Text("No panels found yet")
                } else {
                    ForEach(ble.panels) { panel in
                        Button {
                            ble.selectPanel(panel.id)
                        } label: {
                            Text(panel.id == ble.connectedPanelID ? "✓ \(panel.name)" : panel.name)
                        }
                    }
                }
            }
            .font(.system(size: 12))

            if ble.hasPreferredPanel {
                Button("Forget this panel") {
                    ble.forgetPanel()
                }
                .font(.system(size: 11))
                .buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit Glowgrid") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    // MARK: - Helpers

    private var currentPanelName: String {
        if let id = ble.connectedPanelID,
           let panel = ble.panels.first(where: { $0.id == id }) {
            return "Panel: \(panel.name)"
        }
        return "Panel: none"
    }

    private func sendMessage() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ble.showText(text)
        message = ""
    }

    /// A menu-item-alike row: full width, tick on the left, no button chrome.
    private func row(title: String, ticked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(ticked ? "✓" : " ")
                    .font(.system(size: 12))
                    .frame(width: 12, alignment: .leading)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
