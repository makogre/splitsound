import SwiftUI

@main
struct SplitSoundApp: App {
    @State private var monitor = AudioProcessMonitor()
    @State private var volumes = AppVolumeStore()
    @State private var engine = MixerEngine()
    @State private var settings = AppSettings()
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some Scene {
        MenuBarExtra {
            MixerView(monitor: monitor, volumes: volumes, engine: engine)
                .task {
                    applySettings()
                    monitor.start()
                    engine.start()
                }
                // Keep taps in sync whenever the process list or settings change.
                .onChange(of: monitor.processes) { syncEngine() }
                .onChange(of: volumes.revision) { syncEngine() }
                .onChange(of: settings.showSystemProcesses) { applySettings() }
                .onChange(of: settings.gracePeriod) { applySettings() }
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                settings: settings,
                launchAtLogin: launchAtLogin,
                volumes: volumes,
                engine: engine
            )
        }
    }

    private func syncEngine() {
        engine.sync(processes: monitor.processes, volumes: volumes)
    }

    private func applySettings() {
        monitor.showSystemProcesses = settings.showSystemProcesses
        monitor.gracePeriod = settings.gracePeriod
    }
}
