import Foundation
import Observation

/// Remembers volume and mute state per app, across restarts.
///
/// Keyed by bundle ID so a setting for Safari still applies after Safari
/// restarts. Processes without a bundle ID fall back to their PID and are
/// therefore deliberately transient.
@Observable
@MainActor
final class AppVolumeStore {
    struct Settings: Codable, Equatable {
        var gain: Float = 1.0
        var isMuted: Bool = false

        /// The factor actually applied to the samples.
        var effectiveGain: Float { isMuted ? 0 : gain }
    }

    private static let defaultsKey = "AppVolumeSettings"
    private static let persistableKeyPrefix = "bundle:"

    /// Counts every change. The app watches this to keep the taps in sync —
    /// a dictionary is awkward as an `onChange` source.
    private(set) var revision = 0

    /// Called after any change, so the engine can follow along even when the
    /// interface is closed.
    @ObservationIgnored var onChanged: (() -> Void)?

    private var settings: [String: Settings] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    static func key(for process: AudioProcess) -> String {
        if let bundleID = process.bundleID, !bundleID.isEmpty {
            return persistableKeyPrefix + bundleID
        }
        return "pid:\(process.pid)"
    }

    subscript(process: AudioProcess) -> Settings {
        get { settings[Self.key(for: process)] ?? Settings() }
        set {
            guard settings[Self.key(for: process)] != newValue else { return }
            settings[Self.key(for: process)] = newValue
            revision &+= 1
            save()
            onChanged?()
        }
    }

    func gain(for process: AudioProcess) -> Float { self[process].effectiveGain }

    /// Whether anything has been customised at all — lets the interface
    /// disable the reset button when there is nothing to reset.
    var hasStoredSettings: Bool { !settings.isEmpty }

    var storedCount: Int { settings.count }

    /// Forgets every stored volume. The engine picks this up through
    /// `revision` and drops the taps that are no longer needed.
    func resetAll() {
        guard !settings.isEmpty else { return }
        settings.removeAll()
        revision &+= 1
        save()
        onChanged?()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Settings].self, from: data)
        else { return }
        settings = decoded
    }

    private func save() {
        // PID-based entries are worthless after a restart and would only
        // clutter the file.
        let persistable = settings.filter { $0.key.hasPrefix(Self.persistableKeyPrefix) }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
