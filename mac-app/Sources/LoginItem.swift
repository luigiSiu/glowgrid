import Foundation
import ServiceManagement

/*
 * "Launch at login", backed by SMAppService.
 *
 * A status panel that stops working after every reboot is a demo, not a tool,
 * so this matters more than its size suggests.
 *
 * SMAppService.mainApp (macOS 13+) registers the app itself as a login item.
 * The older approaches are all worse: a LaunchAgent plist in
 * ~/Library/LaunchAgents means writing XML and hardcoding a path that breaks
 * the moment the app moves, and SMLoginItemSetEnabled is deprecated and needs
 * a separate helper application inside the bundle. This is one call, and the
 * result appears in System Settings > General > Login Items where the user can
 * override it - which is exactly where they will look for it.
 *
 * The catch: the system remembers the registration by bundle identifier AND
 * location. Move Glowgrid.app and the login item points at where it used to
 * be, so it must be re-enabled. Hence the advice to install into
 * /Applications first and turn this on afterwards.
 */
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false

    /// Set when the system refuses a change, so the menu can say so rather
    /// than showing a toggle that silently does nothing.
    @Published private(set) var problem: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            enabled = true
            problem = nil
        case .requiresApproval:
            /*
             * The user (or a profile) has disabled the item in System
             * Settings. Registering again will not override that, so say what
             * is actually wrong instead of pretending it worked.
             */
            enabled = false
            problem = "Allow Glowgrid in System Settings › Login Items"
        case .notFound:
            enabled = false
            problem = nil
        case .notRegistered:
            enabled = false
            problem = nil
        @unknown default:
            enabled = false
            problem = nil
        }
    }

    func toggle() {
        do {
            if enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            problem = nil
        } catch {
            /*
             * Most often seen when the app is run from a temporary or
             * quarantined location, or when the bundle signature is not
             * acceptable to the system.
             */
            problem = error.localizedDescription
        }

        refresh()
    }
}
