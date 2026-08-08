import Foundation

/*
 * The statuses the panel understands.
 *
 * The raw values are the exact strings the firmware parses in parseStatus().
 * Keep them in sync with status_ble/status_ble.ino - the firmware ignores
 * anything it does not recognise, so a typo here fails silently rather than
 * loudly, which is worth remembering when something "does nothing".
 */
enum Status: String, CaseIterable, Identifiable {
    case available
    case busy
    case meeting
    case away
    case off

    var id: String { rawValue }

    /// Label shown in the menu.
    var title: String {
        switch self {
        case .available: return "Available"
        case .busy:      return "Busy"
        case .meeting:   return "In a meeting"
        case .away:      return "Away"
        case .off:       return "Off"
        }
    }

    /// SF Symbol used for the menu bar icon.
    var symbol: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .busy:      return "xmark.circle.fill"
        case .meeting:   return "video.circle.fill"
        case .away:      return "moon.circle.fill"
        case .off:       return "circle"
        }
    }
}

/*
 * Who decides the status.
 *
 * This exists because auto and manual genuinely conflict: with automatic
 * detection running, choosing a status by hand would be silently overwritten
 * within a few seconds when the camera and microphone are seen to be idle.
 *
 * Rather than a hidden timeout, the mode is explicit and visible in the menu:
 * picking a status by hand switches to .manual and stays there until the user
 * selects Automatic again. Predictable beats clever.
 */
enum ControlMode {
    case manual
    case automatic
}
