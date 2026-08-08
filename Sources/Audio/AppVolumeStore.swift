import Foundation
import Observation

/// Merkt sich Lautstaerke und Mute pro App — ueber App-Neustarts hinweg.
///
/// Schluessel ist die Bundle-ID, damit die Einstellung fuer Safari auch nach
/// einem Neustart von Safari wieder greift. Prozesse ohne Bundle-ID fallen auf
/// die PID zurueck und sind damit bewusst fluechtig.
@Observable
@MainActor
final class AppVolumeStore {
    struct Settings: Codable, Equatable {
        var gain: Float = 1.0
        var isMuted: Bool = false

        /// Der Faktor, der tatsaechlich auf die Samples angewendet wird.
        var effectiveGain: Float { isMuted ? 0 : gain }
    }

    private static let defaultsKey = "AppVolumeSettings"
    private static let persistableKeyPrefix = "bundle:"

    /// Zaehlt jede Aenderung. Die App haengt daran, um die Taps nachzuziehen —
    /// ein Dictionary ist als `onChange`-Quelle unhandlich.
    private(set) var revision = 0

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
        }
    }

    func gain(for process: AudioProcess) -> Float { self[process].effectiveGain }

    // MARK: - Persistenz

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Settings].self, from: data)
        else { return }
        settings = decoded
    }

    private func save() {
        // PID-basierte Eintraege sind nach einem Neustart wertlos und wuerden
        // die Datei nur zumuellen.
        let persistable = settings.filter { $0.key.hasPrefix(Self.persistableKeyPrefix) }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
