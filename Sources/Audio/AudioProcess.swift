import AppKit
import CoreAudio
import Darwin
import Foundation

/// Eine App, die Audio ausgibt — das, was im Mixer eine Zeile bekommt.
struct AudioProcess: Identifiable, Equatable {
    /// Die Core-Audio-Objekt-ID des Prozesses (nicht die PID).
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?

    /// Gibt der Prozess gerade tatsaechlich Ton aus?
    var isPlayingAudio: Bool
    /// Wann zuletzt Ton kam — damit Zeilen bei kurzen Pausen nicht wegspringen.
    var lastActive: Date

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.id == rhs.id
            && lhs.isPlayingAudio == rhs.isPlayingAudio
            && lhs.name == rhs.name
    }
}

extension AudioProcess {
    /// Liest einen Prozess aus Core Audio aus und reichert ihn mit App-Metadaten an.
    /// Gibt `nil` zurueck, wenn das Objekt keine Ausgabe kann (z. B. reine Aufnahme-Prozesse).
    init?(objectID: AudioObjectID) {
        guard let pid: pid_t = try? objectID.read(kAudioProcessPropertyPID) else { return nil }

        // Prozesse ohne Output-Faehigkeit gehoeren nicht in einen Ausgabe-Mixer.
        guard objectID.hasProperty(kAudioProcessPropertyIsRunningOutput) else { return nil }

        // Core Audio liefert fuer Prozesse ohne Bundle einen leeren String,
        // kein nil — sonst rutscht "" als Anzeigename durch.
        let rawBundleID = try? objectID.readString(kAudioProcessPropertyBundleID)
        let bundleID = (rawBundleID?.isEmpty == false) ? rawBundleID : nil

        let isPlaying = ((try? objectID.read(kAudioProcessPropertyIsRunningOutput) as UInt32) ?? 0) != 0
        let identity = AppIdentity.resolve(pid: pid, bundleID: bundleID)

        self.id = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = identity.name
        self.icon = identity.icon
        self.isPlayingAudio = isPlaying
        self.lastActive = isPlaying ? Date() : .distantPast
    }
}

/// Aufloesung von PID/Bundle-ID zu Anzeigename und Icon.
enum AppIdentity {
    struct Resolved {
        let name: String
        let icon: NSImage?
    }

    static func resolve(pid: pid_t, bundleID: String?) -> Resolved {
        // Beste Quelle: die laufende App selbst.
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName {
            return Resolved(name: name, icon: app.icon)
        }

        // Zweitbeste: ueber die Bundle-ID die App auf der Platte finden.
        // Greift u. a. bei Helper-Prozessen, die selbst keine NSRunningApplication sind.
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return Resolved(name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        }

        // Kommandozeilen-Prozesse (afplay, ffmpeg …) haben weder Bundle noch Icon.
        if let executableName = executableName(for: pid) {
            return Resolved(name: executableName, icon: nil)
        }

        return Resolved(name: bundleID ?? "PID \(pid)", icon: nil)
    }

    /// Name der ausfuehrbaren Datei zu einer PID, via libproc.
    private static func executableName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
