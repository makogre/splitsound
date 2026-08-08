import Foundation
import Observation
import OSLog
import ServiceManagement

/// User-facing preferences, persisted in UserDefaults.
@Observable
@MainActor
final class AppSettings {
    /// Show system daemons (System Sounds, mediaremoted, …) in the mixer.
    /// Off by default: they appear whenever the system makes any noise and
    /// would push the apps the user cares about out of view.
    var showSystemProcesses: Bool {
        didSet { defaults.set(showSystemProcesses, forKey: Keys.showSystemProcesses) }
    }

    /// How long a silenced app stays visible, in seconds.
    var gracePeriod: TimeInterval {
        didSet { defaults.set(gracePeriod, forKey: Keys.gracePeriod) }
    }

    static let gracePeriodChoices: [TimeInterval] = [10, 30, 60, 300]

    private enum Keys {
        static let showSystemProcesses = "showSystemProcesses"
        static let gracePeriod = "gracePeriod"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.showSystemProcesses = defaults.bool(forKey: Keys.showSystemProcesses)
        let storedGrace = defaults.double(forKey: Keys.gracePeriod)
        self.gracePeriod = storedGrace > 0 ? storedGrace : 30
    }
}

/// Wraps the login item registration.
///
/// `SMAppService.mainApp` needs no helper bundle, but it does need a stable
/// code signature — with an ad-hoc build the registration can be forgotten
/// between builds.
@Observable
@MainActor
final class LaunchAtLogin {
    private(set) var isEnabled: Bool
    private(set) var lastError: String?

    private let log = Logger(subsystem: "com.maxgrell.SplitSound", category: "LaunchAtLogin")

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the state from the system. The user can remove the login item
    /// in System Settings without telling us.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            log.error("Login item change failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        refresh()
    }
}

/// What we can honestly say about our ability to capture audio.
///
/// There is deliberately no permission query here. `AVCaptureDevice`
/// `.authorizationStatus(for: .audio)` reports `notDetermined` for this app
/// even while its taps are demonstrably delivering audio — the microphone
/// permission simply is not the gate for process taps, and displaying it
/// produced a false alarm.
///
/// Since macOS also denies tap access by delivering *silence rather than an
/// error*, the only trustworthy signal is whether samples actually arrive.
enum AudioAccess {
    /// What the running taps actually see.
    enum Observed {
        /// Nothing is being adjusted, so there is nothing to report.
        case idle
        /// Samples are arriving — audio access demonstrably works.
        case receivingAudio
        /// Taps are running but no samples have arrived. Either the tapped app
        /// is genuinely silent, or the permission is missing.
        case noSignal
    }

    /// Lands the user in Privacy & Security. Deliberately the root pane: we
    /// could not determine which specific service governs process taps, so
    /// pointing at a named sub-pane would be a guess.
    static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
    )!
}
