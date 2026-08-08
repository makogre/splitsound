import SwiftUI

@main
struct SplitSoundApp: App {
    @State private var monitor = AudioProcessMonitor()
    @State private var volumes = AppVolumeStore()
    @State private var engine = MixerEngine()

    var body: some Scene {
        MenuBarExtra {
            MixerView(monitor: monitor, volumes: volumes, engine: engine)
                .task {
                    monitor.start()
                    engine.start()
                }
                // Keep taps in sync whenever the process list or settings change.
                .onChange(of: monitor.processes) { syncEngine() }
                .onChange(of: volumes.revision) { syncEngine() }
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }

    private func syncEngine() {
        engine.sync(processes: monitor.processes, volumes: volumes)
    }
}
