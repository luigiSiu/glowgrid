import Foundation
import EventKit

/*
 * Reports whether a meeting is happening right now, according to the calendar.
 *
 * Camera and microphone detection answers "are you talking to someone", which
 * is not the same question. The gap it leaves is the one that matters most:
 * for the first minutes of a meeting - while you are walking to a room, or
 * waiting with your camera off - the panel cheerfully says Available, which is
 * precisely when someone is most likely to interrupt you. The calendar knows
 * before the hardware does.
 *
 * It is off by default. Reading someone's calendar is a real privacy step, and
 * turning it on should be a deliberate choice, not something that happens
 * silently on first launch.
 */
@MainActor
final class CalendarSensor: ObservableObject {
    enum Access: Equatable {
        case notDetermined
        case granted
        case denied

        var description: String {
            switch self {
            case .notDetermined: return "Calendar access not requested"
            case .granted:       return "Calendar access granted"
            case .denied:        return "Calendar access denied"
            }
        }
    }

    @Published private(set) var access: Access = .notDetermined

    /// Title of the meeting currently driving the status, for the menu.
    @Published private(set) var currentEventTitle: String?

    private let store = EKEventStore()

    init() {
        access = Self.currentAccess()
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .authorized:
            // macOS 13 and earlier. Deprecated on 14+ but still reported for
            // apps granted access before the split into full/write-only.
            return .granted
        case .fullAccess:
            return .granted
        case .writeOnly:
            // Enough to add events, not to read them - useless here.
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Ask the system for permission. Shows the standard prompt once; after
    /// that the answer comes from System Settings.
    func requestAccess() async {
        /*
         * macOS 14 split calendar permission into full and write-only, and
         * deprecated the old single-purpose call. Both paths are kept because
         * the app still supports macOS 13.
         */
        if #available(macOS 14.0, *) {
            _ = try? await store.requestFullAccessToEvents()
        } else {
            _ = try? await store.requestAccess(to: .event)
        }

        access = Self.currentAccess()
    }

    /// True when an event that looks like a real meeting is in progress.
    func inMeeting() -> Bool {
        guard access == .granted else {
            currentEventTitle = nil
            return false
        }

        let now = Date()

        /*
         * The predicate window has to be wider than a single instant: EventKit
         * matches events overlapping the range, and a zero-width range is
         * unreliable. A minute either side is enough and keeps the query cheap.
         */
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(60),
            calendars: nil
        )

        let match = store.events(matching: predicate).first { event in
            guard let start = event.startDate, let end = event.endDate else { return false }
            guard start <= now, now < end else { return false }

            // All-day entries are usually holidays, birthdays or "on leave" -
            // real information, but not a reason to say you are in a meeting.
            if event.isAllDay { return false }

            // Blocks marked Free are placeholders and reminders, not meetings.
            if event.availability == .free { return false }

            if event.status == .canceled { return false }

            // An invitation you declined should not make you look busy.
            if let me = event.attendees?.first(where: { $0.isCurrentUser }),
               me.participantStatus == .declined {
                return false
            }

            return true
        }

        currentEventTitle = match?.title
        return match != nil
    }
}
