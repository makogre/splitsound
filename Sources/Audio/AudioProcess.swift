import AppKit
import CoreAudio
import Darwin
import Foundation

/// An app that produces audio output — one row in the mixer.
struct AudioProcess: Identifiable, Equatable {
    /// The Core Audio object ID of the process (not the PID).
    let id: AudioObjectID
    let pid: pid_t
    /// Bundle ID used to persist settings. For helper processes this is the
    /// host app's bundle ID, so a setting survives across helper restarts.
    let bundleID: String?
    let name: String
    let icon: NSImage?

    /// Is the process producing audio right now?
    var isPlayingAudio: Bool
    /// When audio was last heard — keeps rows from vanishing during short pauses.
    var lastActive: Date

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.id == rhs.id
            && lhs.isPlayingAudio == rhs.isPlayingAudio
            && lhs.name == rhs.name
    }
}

extension AudioProcess {
    /// Reads a process from Core Audio and enriches it with app metadata.
    /// Returns `nil` for objects that cannot output audio (capture-only processes).
    init?(objectID: AudioObjectID) {
        guard let pid: pid_t = try? objectID.read(kAudioProcessPropertyPID) else { return nil }

        // Processes without output capability do not belong in an output mixer.
        guard objectID.hasProperty(kAudioProcessPropertyIsRunningOutput) else { return nil }

        // Core Audio returns an empty string rather than nil for bundle-less
        // processes; without this, "" would slip through as a display name.
        let rawBundleID = try? objectID.readString(kAudioProcessPropertyBundleID)
        let bundleID = (rawBundleID?.isEmpty == false) ? rawBundleID : nil

        let isPlaying = ((try? objectID.read(kAudioProcessPropertyIsRunningOutput) as UInt32) ?? 0) != 0
        let identity = AppIdentity.resolve(pid: pid, bundleID: bundleID)

        self.id = objectID
        self.pid = pid
        self.bundleID = identity.bundleID
        self.name = identity.name
        self.icon = identity.icon
        self.isPlayingAudio = isPlaying
        self.lastActive = isPlaying ? Date() : .distantPast
    }
}

/// Resolves a PID / bundle ID into a display name, an icon, and the bundle ID
/// that settings should be stored under.
enum AppIdentity {
    struct Resolved {
        let name: String
        let icon: NSImage?
        let bundleID: String?
    }

    /// Helper processes that play audio on behalf of a host app.
    ///
    /// WebKit is the case that matters in practice: Safari's audio does not come
    /// from Safari but from its GPU helper, which reports itself as
    /// "Safari Graphics and Media" with the bundle ID `com.apple.WebKit.GPU`.
    /// Every WebKit browser shares that bundle ID, so without this mapping all
    /// of them would collapse into a single mixer entry — and share one setting.
    private static let helperBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.Networking",
    ]

    /// Suffixes macOS appends to a helper's display name. Stripping one yields
    /// the host app's name.
    private static let helperSuffixes = [
        " Graphics and Media",
        " Web Content",
        " Networking",
    ]

    static func resolve(pid: pid_t, bundleID: String?) -> Resolved {
        let runningApp = NSRunningApplication(processIdentifier: pid)

        // Helper process: show the host app instead. This is a heuristic —
        // macOS exposes no supported way to ask "who is this helper working
        // for" — so it falls back to the helper's own name if no host matches.
        if let bundleID, helperBundleIDs.contains(bundleID),
           let helperName = runningApp?.localizedName,
           let host = hostApplication(forHelperNamed: helperName) {
            return Resolved(
                name: host.localizedName ?? helperName,
                icon: host.icon,
                bundleID: host.bundleIdentifier ?? bundleID
            )
        }

        // Best source: the running app itself.
        if let runningApp, let name = runningApp.localizedName {
            return Resolved(name: name, icon: runningApp.icon, bundleID: bundleID)
        }

        // Next best: locate the app on disk via its bundle ID. Covers helpers
        // that are not an NSRunningApplication in their own right.
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return Resolved(
                name: name,
                icon: NSWorkspace.shared.icon(forFile: url.path),
                bundleID: bundleID
            )
        }

        // Command line processes (afplay, ffmpeg, …) have neither bundle nor icon.
        if let executableName = executableName(for: pid) {
            return Resolved(name: executableName, icon: nil, bundleID: bundleID)
        }

        return Resolved(name: bundleID ?? "PID \(pid)", icon: nil, bundleID: bundleID)
    }

    /// Finds the running app a helper belongs to by stripping the helper suffix
    /// from its display name and matching the remainder against running apps.
    private static func hostApplication(forHelperNamed helperName: String) -> NSRunningApplication? {
        guard let suffix = helperSuffixes.first(where: { helperName.hasSuffix($0) }) else {
            return nil
        }
        let hostName = String(helperName.dropLast(suffix.count))
        guard !hostName.isEmpty else { return nil }

        return NSWorkspace.shared.runningApplications.first { candidate in
            candidate.activationPolicy == .regular
                && candidate.localizedName == hostName
        }
    }

    /// Executable name for a PID, via libproc.
    private static func executableName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
