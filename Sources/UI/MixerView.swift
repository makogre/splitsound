import AppKit
import SwiftUI

/// The mixer itself: one row per app that is producing audio.
struct MixerView: View {
    let monitor: AudioProcessMonitor
    let volumes: AppVolumeStore
    let engine: MixerEngine

    @Environment(\.openSettings) private var openSettings

    /// Measured height of the row list, so the popover window can size to it.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if monitor.processes.isEmpty {
                emptyState
            } else {
                channelList
            }

            Divider()

            footer
        }
        .frame(width: 320)
    }

    /// The rows, scrolling only once there are more than fit.
    ///
    /// The measurement is not decoration. A bare `ScrollView` has no intrinsic
    /// height, and the menu bar window sizes itself to its content — so the
    /// list collapsed to zero height and the popover showed nothing but its
    /// header and footer. Measuring the content and asking for that height
    /// (capped) gives the window something concrete to size to.
    private var channelList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(monitor.processes) { process in
                    AppChannelRow(process: process, volumes: volumes)
                }
            }
            .padding(.vertical, 6)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: min(contentHeight, Self.maximumListHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }

    /// Roughly six rows; beyond that the list scrolls.
    private static let maximumListHeight: CGFloat = 320

    private var header: some View {
        HStack {
            Text("SplitSound")
                .font(.headline)
            Spacer()
            if let error = monitor.lastError ?? engine.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(error)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No app is playing audio right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

            // Opens a real window rather than a second page in here: the
            // popover closes on any click outside it, which makes trying out
            // settings needlessly fiddly.
            //
            // The activation is not optional. As an LSUIElement app we are
            // never the active application, so the settings window opens
            // behind everything else and the button looks broken.
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Spacer()
            donateButton
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Link to the tip jar. Deliberately understated — it should be findable
    /// without getting in the way every time someone adjusts a volume.
    private var donateButton: some View {
        Link(destination: Self.donateURL) {
            HStack(spacing: 4) {
                Image(systemName: "cup.and.saucer.fill")
                Text("Donate")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Support development — buymeacoffee.com/makogre")
    }

    private static let donateURL = URL(string: "https://buymeacoffee.com/makogre")!
}

/// Carries the measured height of the row list up to `MixerView`.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A single channel row: icon, name, mute button, slider.
private struct AppChannelRow: View {
    let process: AudioProcess
    let volumes: AppVolumeStore

    private var settings: Binding<AppVolumeStore.Settings> {
        Binding(
            get: { volumes[process] },
            set: { volumes[process] = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(process.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(Int((settings.wrappedValue.gain * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    muteButton
                    Slider(value: settings.gain, in: 0...1)
                        .controlSize(.small)
                        .disabled(settings.wrappedValue.isMuted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Silent apps linger for a moment but should recede visually.
        .opacity(process.isPlayingAudio ? 1 : 0.55)
    }

    private var icon: some View {
        Group {
            if let icon = process.icon {
                Image(nsImage: icon).resizable()
            } else {
                // Daemons and command line tools have no icon; a fitting
                // symbol reads better than an empty slot.
                Image(systemName: process.symbolName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var muteButton: some View {
        Button {
            settings.wrappedValue.isMuted.toggle()
        } label: {
            Image(systemName: settings.wrappedValue.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(settings.wrappedValue.isMuted ? Color.accentColor : .secondary)
        .help(settings.wrappedValue.isMuted ? "Unmute" : "Mute")
    }
}
