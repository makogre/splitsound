import AppKit
import SwiftUI

/// Der Mixer selbst: eine Zeile pro App, die Ton ausgibt.
struct MixerView: View {
    let monitor: AudioProcessMonitor
    let volumes: AppVolumeStore
    let engine: MixerEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if monitor.processes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(monitor.processes) { process in
                            AppChannelRow(process: process, volumes: volumes)
                        }
                    }
                    .padding(.vertical, 6)
                }
                // Genug fuer ~6 Zeilen, danach scrollt es.
                .frame(maxHeight: 320)
            }

            Divider()

            footer
        }
        .frame(width: 320)
    }

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
            Text("Gerade gibt keine App Ton aus.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Button("Beenden") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Eine Kanalzeile: Icon, Name, Mute-Button, Slider.
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
        // Verstummte Apps bleiben kurz stehen, sollen aber optisch zuruecktreten.
        .opacity(process.isPlayingAudio ? 1 : 0.55)
    }

    private var icon: some View {
        Group {
            if let icon = process.icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
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
        .help(settings.wrappedValue.isMuted ? "Stummschaltung aufheben" : "Stummschalten")
    }
}
