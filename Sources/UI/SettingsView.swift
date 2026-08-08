import AppKit
import SwiftUI

struct SettingsView: View {
    let settings: AppSettings
    let launchAtLogin: LaunchAtLogin
    let volumes: AppVolumeStore
    let engine: MixerEngine

    /// Sampled while this window is open. The tap's peak level lives behind a
    /// raw pointer for the realtime thread, so it cannot drive SwiftUI on its own.
    @State private var observed: AudioAccess.Observed = .idle
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if let error = launchAtLogin.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !launchAtLogin.isInStableLocation {
                    Label(
                        "SplitSound is not running from your Applications folder. "
                        + "A login item added now points at the current location and "
                        + "stops working once that location goes away.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Mixer") {
                Toggle("Show system processes", isOn: Binding(
                    get: { settings.showSystemProcesses },
                    set: { settings.showSystemProcesses = $0 }
                ))
                Text("System Sounds and background services appear whenever macOS "
                     + "makes any noise. Hidden by default so they do not crowd out your apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Keep silent apps listed for", selection: Binding(
                    get: { settings.gracePeriod },
                    set: { settings.gracePeriod = $0 }
                )) {
                    ForEach(AppSettings.gracePeriodChoices, id: \.self) { seconds in
                        Text(Self.durationLabel(seconds)).tag(seconds)
                    }
                }
            }

            Section("Audio access") {
                observedRow
            }

            Section("Saved volumes") {
                HStack {
                    Text(volumes.hasStoredSettings
                         ? "Volumes you set are remembered per app."
                         : "Nothing saved yet.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset…") { showResetConfirmation = true }
                        .disabled(!volumes.hasStoredSettings)
                }
                Text("Use this if an app is unexpectedly quiet and you cannot "
                     + "remember which setting caused it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                Link(destination: Self.repositoryURL) {
                    Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Self.donateURL) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
                Text("MIT licensed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task { await pollAudioAccess() }
        .onAppear { launchAtLogin.refresh() }
        .confirmationDialog(
            "Reset all saved volumes?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { volumes.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every app returns to 100 % and unmuted. This cannot be undone.")
        }
    }

    // MARK: - Audio access

    /// Reports what the taps actually receive, rather than a permission flag.
    ///
    /// macOS denies tap access by delivering silence instead of an error, and
    /// the queryable microphone permission does not reflect tap access at all
    /// — so only observed samples tell the truth.
    @ViewBuilder
    private var observedRow: some View {
        switch observed {
        case .idle:
            Label("Nothing being adjusted right now", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
            Text("Turn an app down in the mixer; this will then confirm whether "
                 + "its audio is actually reaching SplitSound.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .receivingAudio:
            Label("Audio is coming through", systemImage: "waveform")
                .foregroundStyle(.green)
            Text("SplitSound is receiving samples, so volume control is working.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .noSignal:
            HStack {
                Label("No audio received", systemImage: "waveform.slash")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Privacy Settings…") {
                    NSWorkspace.shared.open(AudioAccess.privacySettingsURL)
                }
            }
            Text("An app is being adjusted but no sound is arriving. Either it is "
                 + "silent at the moment, or macOS is withholding audio access — "
                 + "which it does without ever showing an error.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Samples the running taps while this window is visible. Stops as soon as
    /// the task is cancelled, so nothing polls in the background.
    private func pollAudioAccess() async {
        var sawRenders = false
        while !Task.isCancelled {
            let statuses = engine.activeTapStatuses
            if statuses.contains(where: { $0.peakLevel > 0.0001 }) {
                observed = .receivingAudio
            } else if statuses.contains(where: { $0.renderCount > 100 }) {
                // Rendering for a while without a single sample.
                observed = sawRenders ? .noSignal : .idle
                sawRenders = true
            } else {
                observed = .idle
                sawRenders = false
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: - Constants

    private static let repositoryURL = URL(string: "https://github.com/makogre/splitsound")!
    private static let donateURL = URL(string: "https://buymeacoffee.com/makogre")!

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? "\(Int(seconds)) seconds"
            : (seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes")
    }
}
