import CoreAudio
import Foundation
import Observation
import OSLog

/// Haelt die aktiven Taps im Einklang mit dem, was der Nutzer eingestellt hat.
///
/// Getappt wird nur, was tatsaechlich geregelt werden soll. Eine App auf 100 %
/// ohne Mute laeuft unangetastet am schnellsten Weg zum Lautsprecher — ein Tap
/// wuerde dort nur Latenz und CPU kosten.
@Observable
@MainActor
final class MixerEngine {
    /// Ein Tap plus die PID, fuer die er angelegt wurde.
    ///
    /// Core Audio vergibt Prozess-Objekt-IDs wieder: dieselbe ID stand im Test
    /// nacheinander fuer mehrere verschiedene Prozesse. Ohne die PID danebenzulegen
    /// wuerde ein alter Tap stillschweigend auf die falsche App zeigen.
    private struct Entry {
        let tap: ProcessTap
        let pid: pid_t
    }

    private var entries: [AudioObjectID: Entry] = [:]
    @ObservationIgnored private var outputDeviceObservation: PropertyObservation?

    private(set) var lastError: String?

    private let log = Logger(subsystem: "com.maxgrell.SplitSound", category: "MixerEngine")

    /// Was ein aktiver Tap gerade tut. Grundlage für Pegelanzeigen und Fehlersuche.
    struct TapStatus {
        /// Spitzenpegel (0…1) des zuletzt verarbeiteten Blocks.
        let peakLevel: Float
        /// Bisherige Durchläufe des Realtime-Callbacks. Steigt die Zahl nicht,
        /// läuft die Audiokette nicht.
        let renderCount: UInt64
    }

    var activeTapCount: Int { entries.count }

    func status(for process: AudioProcess) -> TapStatus? {
        guard let entry = entries[process.id], entry.pid == process.pid else { return nil }
        return TapStatus(peakLevel: entry.tap.peakLevel, renderCount: entry.tap.renderCount)
    }

    func start() {
        // Wechselt der Nutzer die Ausgabe (Kopfhoerer rein), zeigen alle
        // Aggregate Devices auf das falsche Geraet und muessen neu gebaut werden.
        outputDeviceObservation = try? AudioObjectID.system
            .observe(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                MainActor.assumeIsolated { self?.rebuildAll() }
            }
    }

    func stop() {
        outputDeviceObservation = nil
        entries.removeAll()
    }

    /// Bringt die Taps auf den Stand von Prozessliste und Nutzereinstellungen.
    func sync(processes: [AudioProcess], volumes: AppVolumeStore) {
        var wanted = Set<AudioObjectID>()

        for process in processes {
            let settings = volumes[process]
            let needsTap = settings.isMuted || settings.gain < 1.0

            guard needsTap else { continue }
            wanted.insert(process.id)

            // Bestehenden Tap wiederverwenden, sofern er noch zur selben App gehoert.
            if let entry = entries[process.id] {
                if entry.pid == process.pid {
                    entry.tap.gain = settings.effectiveGain
                    continue
                }
                // Objekt-ID recycelt: alter Tap gehoert zu einem toten Prozess.
                log.info("Objekt-ID \(process.id) neu vergeben, Tap wird ersetzt")
                entry.tap.invalidate()
                entries[process.id] = nil
            }

            activateTap(for: process, gain: settings.effectiveGain)
        }

        // Alles, was nicht mehr geregelt werden soll, wieder freigeben.
        for (objectID, entry) in entries where !wanted.contains(objectID) {
            entry.tap.invalidate()
            entries[objectID] = nil
        }
    }

    // MARK: - Intern

    private func activateTap(for process: AudioProcess, gain: Float) {
        let tap = ProcessTap(processObjectID: process.id, gain: gain)
        do {
            try tap.activate()
            entries[process.id] = Entry(tap: tap, pid: process.pid)
            lastError = nil
        } catch {
            log.error("Tap fuer \(process.name) fehlgeschlagen: \(error.localizedDescription)")
            lastError = "\(process.name): \(error.localizedDescription)"
        }
    }

    /// Baut alle Taps neu auf — noetig, wenn sich das Ausgabegeraet aendert.
    private func rebuildAll() {
        guard !entries.isEmpty else { return }
        log.info("Ausgabegeraet gewechselt, \(self.entries.count) Tap(s) werden neu aufgebaut")

        let snapshot = entries
        entries.removeAll()

        for (objectID, entry) in snapshot {
            let gain = entry.tap.gain
            entry.tap.invalidate()

            let fresh = ProcessTap(processObjectID: objectID, gain: gain)
            do {
                try fresh.activate()
                entries[objectID] = Entry(tap: fresh, pid: entry.pid)
            } catch {
                log.error("Neuaufbau fuer Objekt \(objectID) fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }
}
