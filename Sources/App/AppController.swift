import AppKit
import Foundation
import OSLog

/// Owns the long-lived objects and keeps them running.
///
/// Deliberately an app delegate rather than state on the menu bar scene: the
/// popover's content view only exists while the menu is open, so anything
/// started from it would not run until the user clicks — saved volumes would
/// not apply, and an app that started playing in the meantime would be missed.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let monitor = AudioProcessMonitor()
    let volumes = AppVolumeStore()
    let engine = MixerEngine()
    let settings = AppSettings()
    let launchAtLogin = LaunchAtLogin()

    private let log = Logger(subsystem: "com.maxgrell.SplitSound", category: "AppController")

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Launched; \(self.volumes.storedCount) stored volume(s)")
        applySettings()

        // Both sides push into the engine, so it stays correct while the
        // interface is closed.
        monitor.onProcessesChanged = { [weak self] in self?.syncEngine() }
        volumes.onChanged = { [weak self] in self?.syncEngine() }
        settings.onChanged = { [weak self] in self?.applySettings() }

        engine.start()
        monitor.start()
        syncEngine()

    }

    func applicationWillTerminate(_ notification: Notification) {
        // Drops the taps, so every app returns to its own unmodified output
        // rather than staying muted by a tap nobody is reading any more.
        engine.stop()
        monitor.stop()
    }

    func applySettings() {
        monitor.showSystemProcesses = settings.showSystemProcesses
        monitor.gracePeriod = settings.gracePeriod
    }

    private func syncEngine() {
        engine.sync(processes: monitor.processes, volumes: volumes)
    }
}
