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
    /// SF Symbol shown when there is no app icon — daemons and command line
    /// tools have none, and never will.
    let symbolName: String

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
        self.symbolName = identity.symbolName
        self.isPlayingAudio = isPlaying
        self.lastActive = isPlaying ? Date() : .distantPast
    }
}

/// Resolves a PID / bundle ID into a display name, an icon, and the bundle ID
/// that settings should be stored under.
///
/// Two kinds of process need help here. Nested helpers live inside another
/// app's bundle and can be attributed to it generically, by walking the
/// executable path upwards. XPC services live outside their host's bundle
/// entirely — WebKit is the one that matters — and need the name heuristic.
enum AppIdentity {
    struct Resolved {
        let name: String
        let icon: NSImage?
        let bundleID: String?
        var symbolName: String = "app.dashed"
    }

    /// System daemons worth showing under a human name. They have no icon and
    /// never will, so a fitting symbol stands in.
    private static let systemProcesses: [String: (name: String, symbol: String)] = [
        "systemsoundserverd": ("System Sounds", "speaker.wave.2.fill"),
    ]

    /// XPC services that play audio on behalf of a host app but live outside
    /// its bundle, so the path-based rule below cannot find the host.
    ///
    /// WebKit is the case that matters: Safari's audio comes from a service in
    /// WebKit.framework, reporting itself as "Safari Graphics and Media".
    /// Every WebKit browser shares that bundle ID, so without this mapping all
    /// of them would collapse into one entry — and share a single setting.
    private static let helperBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.Networking",
    ]

    /// Suffixes macOS appends to such a service's display name. Stripping one
    /// yields the host app's name.
    private static let helperSuffixes = [
        " Graphics and Media",
        " Web Content",
        " Networking",
    ]

    static func resolve(pid: pid_t, bundleID: String?) -> Resolved {
        let path = executablePath(for: pid)
        let runningApp = NSRunningApplication(processIdentifier: pid)

        // 1. Known system daemon under a readable name.
        if let executable = path.map({ ($0 as NSString).lastPathComponent }),
           let known = systemProcesses[executable] {
            return Resolved(name: known.name, icon: nil, bundleID: bundleID,
                            symbolName: known.symbol)
        }

        // 2. XPC service belonging to a host app. A heuristic — macOS exposes no
        //    supported way to ask who a service is working for — so it falls
        //    through to the generic paths if no host matches.
        if let bundleID, helperBundleIDs.contains(bundleID),
           let helperName = runningApp?.localizedName,
           let host = hostApplication(forHelperNamed: helperName) {
            return Resolved(
                name: host.localizedName ?? helperName,
                icon: host.icon,
                bundleID: host.bundleIdentifier ?? bundleID
            )
        }

        // 3. Executable nested inside another app's bundle — the Electron
        //    pattern (Discord, Teams, VS Code and friends all ship their audio
        //    in a "… Helper.app" inside the main bundle). Walking up the path
        //    handles every such app without naming any of them.
        if let path, let host = enclosingApplication(ofExecutableAt: path),
           host.bundleID != bundleID {
            return Resolved(name: host.name, icon: host.icon, bundleID: host.bundleID)
        }

        // 4. The running app itself.
        if let runningApp, let name = runningApp.localizedName {
            return Resolved(name: name, icon: runningApp.icon, bundleID: bundleID)
        }

        // 5. Locate the app on disk via its bundle ID.
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return Resolved(
                name: FileManager.default.displayName(atPath: url.path),
                icon: NSWorkspace.shared.icon(forFile: url.path),
                bundleID: bundleID
            )
        }

        // 6. Command line tools and daemons: no bundle, no icon, just a name.
        if let executable = executableName(for: pid, path: path) {
            return Resolved(name: executable, icon: nil, bundleID: bundleID,
                            symbolName: "terminal")
        }

        return Resolved(name: "PID \(pid)", icon: nil, bundleID: bundleID)
    }

    // MARK: - Host lookup

    /// The outermost `.app` bundle containing an executable, or `nil` if the
    /// executable does not live inside one.
    ///
    /// Outermost is the point: an Electron helper sits at
    /// `Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper`,
    /// and the interesting bundle is `Foo.app`, not `Foo Helper.app`.
    ///
    /// Pure path arithmetic, no file system access — `internal` so it can be
    /// tested without depending on which apps happen to be installed.
    static func outermostAppBundle(forExecutableAt path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        var outermost: URL?
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { outermost = url }
        }
        return outermost
    }

    /// Resolves the enclosing app bundle to a name, icon and bundle ID.
    private static func enclosingApplication(
        ofExecutableAt path: String
    ) -> (name: String, icon: NSImage?, bundleID: String?)? {
        guard let bundleURL = outermostAppBundle(forExecutableAt: path) else { return nil }

        let bundleID = Bundle(url: bundleURL)?.bundleIdentifier

        // Prefer the running instance: its localized name respects the user's
        // language, the file name does not.
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier != nil && $0.bundleIdentifier == bundleID
        }
        return (
            name: running?.localizedName
                ?? FileManager.default.displayName(atPath: bundleURL.path),
            icon: running?.icon ?? NSWorkspace.shared.icon(forFile: bundleURL.path),
            bundleID: bundleID
        )
    }

    /// Finds the running app an XPC service belongs to by stripping the service
    /// suffix from its display name and matching the remainder.
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

    // MARK: - Process paths

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Executable name for a PID.
    ///
    /// `proc_name` truncates and fails outright for some processes where
    /// `proc_pidpath` still works, which is why the path is the better source
    /// and `proc_name` only the fallback.
    private static func executableName(for pid: pid_t, path: String?) -> String? {
        if let path {
            let component = (path as NSString).lastPathComponent
            if !component.isEmpty { return component }
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
