import CoreAudio
import Foundation
import Observation
import OSLog

/// Verfolgt, welche Apps gerade Audio ausgeben, und haelt die Mixer-Liste aktuell.
///
/// Core Audio meldet Aenderungen per Property-Listener, wir pollen also nicht.
/// Einzige Ausnahme ist der Nachlauf-Timer: er laesst Zeilen nach dem Verstummen
/// noch kurz stehen, damit der Slider beim Pausieren eines Videos nicht wegspringt.
@Observable
@MainActor
final class AudioProcessMonitor {
    /// Wie lange eine verstummte App noch im Mixer sichtbar bleibt.
    static let gracePeriod: TimeInterval = 30

    private(set) var processes: [AudioProcess] = []
    private(set) var lastError: String?

    @ObservationIgnored private var listObservation: PropertyObservation?
    @ObservationIgnored private var processObservations: [AudioObjectID: PropertyObservation] = [:]
    @ObservationIgnored private var lastActiveByProcess: [AudioObjectID: Date] = [:]
    @ObservationIgnored private var graceTimer: Timer?

    private let log = Logger(subsystem: "com.maxgrell.SplitSound", category: "ProcessMonitor")

    func start() {
        do {
            listObservation = try AudioObjectID.system.observe(kAudioHardwarePropertyProcessObjectList) {
                [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } catch {
            log.error("Prozessliste konnte nicht beobachtet werden: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func stop() {
        listObservation = nil
        processObservations.removeAll()
        graceTimer?.invalidate()
        graceTimer = nil
    }

    // MARK: - Aktualisierung

    /// Liest die komplette Prozessliste neu und baut die sichtbare Mixer-Liste auf.
    private func refresh() {
        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)
            lastError = nil
        } catch {
            log.error("Prozessliste nicht lesbar: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return
        }

        var discovered: [AudioProcess] = []
        let now = Date()

        for objectID in objectIDs {
            guard var process = AudioProcess(objectID: objectID) else { continue }

            if process.isPlayingAudio {
                lastActiveByProcess[objectID] = now
            }
            process.lastActive = lastActiveByProcess[objectID] ?? .distantPast

            observeIsRunningOutput(of: objectID)
            discovered.append(process)
        }

        // Listener und Zeitstempel verschwundener Prozesse aufraeumen.
        let liveIDs = Set(objectIDs)
        processObservations = processObservations.filter { liveIDs.contains($0.key) }
        lastActiveByProcess = lastActiveByProcess.filter { liveIDs.contains($0.key) }

        publish(discovered, now: now)
    }

    /// Filtert auf hoerbare bzw. kuerzlich hoerbare Apps und sortiert stabil.
    private func publish(_ candidates: [AudioProcess], now: Date) {
        let visible = candidates
            .filter { $0.isPlayingAudio || now.timeIntervalSince($0.lastActive) < Self.gracePeriod }
            .sorted {
                // Aktive zuerst, danach alphabetisch — so springt nichts grundlos umher.
                if $0.isPlayingAudio != $1.isPlayingAudio { return $0.isPlayingAudio }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        if visible != processes {
            processes = visible
        }
        scheduleGraceExpiryIfNeeded(now: now)
    }

    /// Ein Prozess ist verstummt: der Nachlauf laeuft ab, ohne dass Core Audio
    /// uns nochmal aufweckt. Also einmalig nachfassen, wenn der aelteste
    /// Nachlauf-Eintrag faellig wird.
    private func scheduleGraceExpiryIfNeeded(now: Date) {
        graceTimer?.invalidate()
        graceTimer = nil

        let pendingExpiries = processes
            .filter { !$0.isPlayingAudio }
            .map { $0.lastActive.addingTimeInterval(Self.gracePeriod) }

        guard let next = pendingExpiries.min() else { return }
        let delay = max(next.timeIntervalSince(now), 0.1)

        graceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Sorgt dafuer, dass wir sofort erfahren, wenn eine App zu spielen beginnt oder aufhoert.
    private func observeIsRunningOutput(of objectID: AudioObjectID) {
        guard processObservations[objectID] == nil else { return }
        do {
            processObservations[objectID] = try objectID.observe(kAudioProcessPropertyIsRunningOutput) {
                [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } catch {
            log.debug("Kein Listener fuer Prozess \(objectID): \(error.localizedDescription)")
        }
    }
}
