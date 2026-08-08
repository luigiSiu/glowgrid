import Foundation
import Combine

/*
 * Decides what the panel should show, and pushes it over BLE.
 *
 * The interesting part is the manual/automatic conflict. With detection
 * running, choosing a status by hand would be quietly reverted a few seconds
 * later when the camera and microphone are seen to be idle. Two ways to solve
 * that: a hidden timeout after which auto resumes, or explicit modes.
 *
 * Explicit modes won. A timeout means the panel changes on its own some
 * minutes later with no visible cause, which is exactly the kind of behaviour
 * that makes a tool feel haunted. Here, picking a status switches to manual
 * and stays there until Automatic is chosen from the menu, and the menu always
 * shows which mode is active.
 */
@MainActor
final class StatusController: ObservableObject {
    @Published private(set) var status: Status = .off
    @Published private(set) var mode: ControlMode = .manual

    /*
     * Whether the calendar is consulted as well as the hardware. Off unless
     * the user has turned it on, and remembered so that choice survives a
     * restart - being asked for calendar access on every launch would be
     * obnoxious.
     */
    @Published private(set) var useCalendar: Bool

    private let ble: BLEClient
    private let calendar: CalendarSensor
    private var timer: Timer?

    private let calendarKey = "useCalendar"

    /*
     * Detection is debounced: a new reading must be seen twice in a row before
     * it is acted on. Microphone state blips briefly when apps probe the
     * device, and without this the panel visibly flaps between colours.
     */
    private var candidate: Status?

    /*
     * The debounce is right for ongoing detection but wrong the instant you
     * switch Automatic on: you have just asked for something, so waiting a
     * further poll before anything visibly happens feels broken. The first
     * reading after enabling is therefore applied immediately.
     */
    private var applyNextImmediately = false

    private let pollInterval: TimeInterval = 3.0

    init(ble: BLEClient, calendar: CalendarSensor) {
        self.ble = ble
        self.calendar = calendar
        self.useCalendar = UserDefaults.standard.bool(forKey: calendarKey)
    }

    // MARK: - User actions

    /// Called when a status is chosen from the menu.
    func selectManual(_ status: Status) {
        mode = .manual
        stopPolling()
        apply(status)
    }

    /// Called when Automatic is chosen from the menu.
    func enableAutomatic() {
        mode = .automatic
        candidate = nil
        applyNextImmediately = true
        startPolling()
        poll()          // react now rather than waiting a whole cycle
    }

    /// Called when the calendar option is toggled. Asks for permission the
    /// first time it is switched on.
    func setUseCalendar(_ on: Bool) async {
        if on && calendar.access == .notDetermined {
            await calendar.requestAccess()
        }

        /*
         * If the user refused, leave the switch off rather than showing it on
         * while quietly doing nothing.
         */
        useCalendar = on && calendar.access == .granted
        UserDefaults.standard.set(useCalendar, forKey: calendarKey)

        if mode == .automatic {
            applyNextImmediately = true
            poll()
        }
    }

    // MARK: - Automatic detection

    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard mode == .automatic else { return }

        let camera = MediaSensor.cameraInUse()
        let mic = MediaSensor.microphoneInUse()
        let scheduled = useCalendar && calendar.inMeeting()
        let wanted = decide(camera: camera, mic: mic, scheduled: scheduled)

        if wanted == status {
            candidate = nil
            applyNextImmediately = false
            return
        }

        if applyNextImmediately || wanted == candidate {
            applyNextImmediately = false
            candidate = nil
            apply(wanted)
        } else {
            candidate = wanted
        }
    }

    /*
     * Order matters. The calendar outranks the microphone because a scheduled
     * meeting you are listening to in silence is still a meeting, while the
     * microphone alone only proves something is recording - which could be
     * dictation. Camera stays first: if it is on, you are unambiguously on a
     * call, whether or not anyone put it in a calendar.
     */
    private func decide(camera: Bool, mic: Bool, scheduled: Bool) -> Status {
        if camera { return .meeting }
        if scheduled { return .meeting }
        if mic { return .busy }
        return .available
    }

    // MARK: - Output

    private func apply(_ new: Status) {
        status = new
        ble.send(new)
    }
}
