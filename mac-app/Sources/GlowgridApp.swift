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
    @StateObject private var calendar: CalendarSensor
    @StateObject private var loginItem = LoginItem()

    init() {
        // One client and one calendar sensor, shared by the menu (which shows
        // their state) and the controller (which uses them). Declared without
        // inline initialisers so they are not built twice.
        let client = BLEClient()
        let calendarSensor = CalendarSensor()
        _ble = StateObject(wrappedValue: client)
        _calendar = StateObject(wrappedValue: calendarSensor)
        _controller = StateObject(
            wrappedValue: StatusController(ble: client, calendar: calendarSensor)
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(ble: ble, controller: controller,
                        calendar: calendar, loginItem: loginItem)
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
    @ObservedObject var calendar: CalendarSensor
    @ObservedObject var loginItem: LoginItem

    @State private var message: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !ble.isConnected {
                offlineNote
            }
            Divider()
            statusSection
            Divider()
            brightnessSection
            Divider()
            messageSection
            Divider()
            panelSection
            Divider()
            settingsSection
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

    /// Shown only while disconnected, to explain the greyed-out controls and to
    /// promise that a status chosen now is not being thrown away.
    private var offlineNote: some View {
        Text("Pick a status anyway - it will be applied when the panel is back.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

            // Indented, because it modifies Automatic rather than being an
            // alternative to it.
            row(title: "…and my calendar", ticked: controller.useCalendar, indent: 20) {
                Task { await controller.setUseCalendar(!controller.useCalendar) }
            }

            if controller.useCalendar, let title = calendar.currentEventTitle {
                Text("In: \(title)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 40)
            }

            if calendar.access == .denied {
                Text("Calendar access denied - enable it in System Settings › Privacy")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 40)
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
        /*
         * Brightness and messages act on the panel immediately or not at all,
         * so they are disabled while it is unreachable rather than accepting
         * input that goes nowhere. Statuses stay enabled on purpose: the app
         * remembers your choice and applies it the moment the panel returns.
         */
        .disabled(!ble.isConnected)
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
        .disabled(!ble.isConnected)
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

            HStack(spacing: 10) {
                // Scanning stops once connected, so finding a second panel has
                // to be asked for rather than happening continuously.
                Button("Rescan") {
                    ble.rescan()
                }
                .font(.system(size: 11))
                .buttonStyle(.link)

                if ble.hasPreferredPanel {
                    Button("Forget this panel") {
                        ble.forgetPanel()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.link)
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(title: "Launch at login", ticked: loginItem.enabled) {
                loginItem.toggle()
            }

            if let problem = loginItem.problem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
        .onAppear {
            // The user can turn the login item off in System Settings behind
            // our back, so the state is re-read every time the panel opens.
            loginItem.refresh()
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
    private func row(title: String,
                     ticked: Bool,
                     indent: CGFloat = 0,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(ticked ? "✓" : " ")
                    .font(.system(size: 12))
                    .frame(width: 12, alignment: .leading)
                    .padding(.leading, indent)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
