import SwiftUI

@main
struct SplitSoundApp: App {
    /// The controller starts monitoring at launch. Doing it from the menu bar
    /// content instead would defer everything until the user first opens the
    /// menu — see AppController.
    @NSApplicationDelegateAdaptor(AppController.self) private var controller

    var body: some Scene {
        MenuBarExtra {
            MixerView(
                monitor: controller.monitor,
                volumes: controller.volumes,
                engine: controller.engine
            )
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                settings: controller.settings,
                launchAtLogin: controller.launchAtLogin,
                volumes: controller.volumes,
                engine: controller.engine
            )
        }
    }
}
