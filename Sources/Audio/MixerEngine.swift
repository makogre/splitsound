import CoreAudio
import Foundation
import Observation
import OSLog

/// Keeps the active taps in sync with what the user has configured.
///
/// Only apps that actually need adjusting are tapped. An app at 100% and
/// unmuted keeps its untouched, lowest-latency path to the speakers; a tap
/// there would only cost latency and CPU.
@Observable
@MainActor
final class MixerEngine {
    /// A tap plus the PID it was created for.
    ///
    /// Core Audio reuses process object IDs: during testing the same ID stood
    /// for several different processes in succession. Without the PID
    /// alongside it, a stale tap would silently point at the wrong app.
    private struct Entry {
        let tap: ProcessTap
        let pid: pid_t
    }

    private var entries: [AudioObjectID: Entry] = [:]
    @ObservationIgnored private var outputDeviceObservation: PropertyObservation?

    private(set) var lastError: String?

    private let log = Logger(subsystem: "com.maxgrell.SplitSound", category: "MixerEngine")

    /// What an active tap is currently doing. Basis for level meters and
    /// for diagnosing a silent chain.
    struct TapStatus {
        /// Peak level (0…1) of the most recently processed block.
        let peakLevel: Float
        /// Realtime callback invocations so far. If this stops climbing,
        /// the audio chain is not running.
        let renderCount: UInt64
    }

    var activeTapCount: Int { entries.count }

    /// Snapshot of every active tap. Read live, so callers must poll — the
    /// underlying values live behind raw pointers for the realtime thread and
    /// cannot notify observers.
    var activeTapStatuses: [TapStatus] {
        entries.values.map {
            TapStatus(peakLevel: $0.tap.peakLevel, renderCount: $0.tap.renderCount)
        }
    }

    func status(for process: AudioProcess) -> TapStatus? {
        guard let entry = entries[process.id], entry.pid == process.pid else { return nil }
        return TapStatus(peakLevel: entry.tap.peakLevel, renderCount: entry.tap.renderCount)
    }

    func start() {
        // When the user switches output (plugs in headphones), every aggregate
        // device points at the wrong device and has to be rebuilt.
        outputDeviceObservation = try? AudioObjectID.system
            .observe(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                MainActor.assumeIsolated { self?.rebuildAll() }
            }
    }

    func stop() {
        outputDeviceObservation = nil
        entries.removeAll()
    }

    /// Brings the taps in line with the process list and the user's settings.
    func sync(processes: [AudioProcess], volumes: AppVolumeStore) {
        var wanted = Set<AudioObjectID>()

        for process in processes {
            let settings = volumes[process]
            let needsTap = settings.isMuted || settings.gain < 1.0

            guard needsTap else { continue }
            wanted.insert(process.id)

            // Reuse an existing tap as long as it still belongs to the same app.
            if let entry = entries[process.id] {
                if entry.pid == process.pid {
                    entry.tap.gain = settings.effectiveGain
                    continue
                }
                // Object ID recycled: the old tap belongs to a dead process.
                log.info("Object ID \(process.id) was reassigned, replacing tap")
                entry.tap.invalidate()
                entries[process.id] = nil
            }

            activateTap(for: process, gain: settings.effectiveGain)
        }

        // Release anything that no longer needs adjusting.
        for (objectID, entry) in entries where !wanted.contains(objectID) {
            entry.tap.invalidate()
            entries[objectID] = nil
        }
    }

    // MARK: - Internals

    private func activateTap(for process: AudioProcess, gain: Float) {
        let tap = ProcessTap(processObjectID: process.id, gain: gain)
        do {
            try tap.activate()
            entries[process.id] = Entry(tap: tap, pid: process.pid)
            lastError = nil
        } catch {
            log.error("Tap for \(process.name) failed: \(error.localizedDescription)")
            lastError = "\(process.name): \(error.localizedDescription)"
        }
    }

    /// Rebuilds every tap — required when the output device changes.
    private func rebuildAll() {
        guard !entries.isEmpty else { return }
        log.info("Output device changed, rebuilding \(self.entries.count) tap(s)")

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
                log.error("Rebuild for object \(objectID) failed: \(error.localizedDescription)")
            }
        }
    }
}
