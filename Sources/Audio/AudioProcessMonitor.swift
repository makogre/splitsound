import CoreAudio
import Foundation
import Observation
import OSLog

/// Tracks which apps are currently producing audio and keeps the mixer list current.
///
/// Core Audio reports changes through property listeners, so there is no polling.
/// The one exception is the grace timer: it keeps rows visible for a moment after
/// an app falls silent, so the slider does not disappear when a video is paused.
@Observable
@MainActor
final class AudioProcessMonitor {
    /// How long a silenced app stays visible in the mixer. Driven by settings.
    var gracePeriod: TimeInterval = 30 {
        didSet { if gracePeriod != oldValue { refresh() } }
    }

    /// Whether system daemons appear in the list. Driven by settings.
    var showSystemProcesses = false {
        didSet { if showSystemProcesses != oldValue { refresh() } }
    }

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
            log.error("Could not observe process list: \(error.localizedDescription)")
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

    // MARK: - Refresh

    /// Re-reads the full process list and rebuilds the visible mixer list.
    private func refresh() {
        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList)
            lastError = nil
        } catch {
            log.error("Process list unreadable: \(error.localizedDescription)")
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

        // Drop listeners and timestamps for processes that are gone.
        let liveIDs = Set(objectIDs)
        processObservations = processObservations.filter { liveIDs.contains($0.key) }
        lastActiveByProcess = lastActiveByProcess.filter { liveIDs.contains($0.key) }

        publish(discovered, now: now)
    }

    /// Filters down to audible (or recently audible) apps and sorts them stably.
    private func publish(_ candidates: [AudioProcess], now: Date) {
        let visible = candidates
            .filter { showSystemProcesses || !$0.isSystemProcess }
            .filter { $0.isPlayingAudio || now.timeIntervalSince($0.lastActive) < gracePeriod }
            .sorted {
                // Active first, then alphabetical — so nothing jumps around without reason.
                if $0.isPlayingAudio != $1.isPlayingAudio { return $0.isPlayingAudio }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        if visible != processes {
            processes = visible
        }
        scheduleGraceExpiryIfNeeded(now: now)
    }

    /// A process has fallen silent: its grace period will expire without Core
    /// Audio waking us again. So check back once, when the earliest pending
    /// grace period runs out.
    private func scheduleGraceExpiryIfNeeded(now: Date) {
        graceTimer?.invalidate()
        graceTimer = nil

        let pendingExpiries = processes
            .filter { !$0.isPlayingAudio }
            .map { $0.lastActive.addingTimeInterval(gracePeriod) }

        guard let next = pendingExpiries.min() else { return }
        let delay = max(next.timeIntervalSince(now), 0.1)

        graceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Ensures we hear about it immediately when an app starts or stops playing.
    private func observeIsRunningOutput(of objectID: AudioObjectID) {
        guard processObservations[objectID] == nil else { return }
        do {
            processObservations[objectID] = try objectID.observe(kAudioProcessPropertyIsRunningOutput) {
                [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } catch {
            log.debug("No listener for process \(objectID): \(error.localizedDescription)")
        }
    }
}
