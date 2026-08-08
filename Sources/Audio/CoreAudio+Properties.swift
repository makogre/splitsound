import CoreAudio
import Foundation

/// Fehler aus der Core-Audio-C-API, angereichert um den lesbaren FourCC-Code.
struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) fehlgeschlagen: \(status.fourCharCode) (\(status))"
    }
}

extension OSStatus {
    /// Core Audio kodiert Fehler meist als FourCC ('!obj', 'nope', …).
    /// Nicht druckbare Codes werden als Zahl dargestellt.
    var fourCharCode: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "\(self)" }
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }

    /// Wirft, falls der Status kein Erfolg ist.
    func check(_ operation: String) throws {
        guard self == noErr else { throw CoreAudioError(status: self, operation: operation) }
    }
}

extension AudioObjectPropertyAddress {
    /// Kurzform fuer den mit Abstand haeufigsten Fall: global scope, main element.
    static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    // MARK: - Lesen

    /// Liest eine Property fester Groesse (Int32, UInt32, Bool32, Structs …).
    func read<T>(_ selector: AudioObjectPropertySelector, as type: T.Type = T.self) throws -> T {
        var address = AudioObjectPropertyAddress.global(selector)
        var size = UInt32(MemoryLayout<T>.size)

        let value = try withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer -> T in
            let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
            try status.check("Lesen von \(selector.fourCharCode) auf Objekt \(self)")
            return buffer.baseAddress!.pointee
        }
        return value
    }

    /// Liest eine Property variabler Laenge als Array (z. B. Objektlisten).
    func readArray<T>(_ selector: AudioObjectPropertySelector, of type: T.Type = T.self) throws -> [T] {
        var address = AudioObjectPropertyAddress.global(selector)
        var byteSize: UInt32 = 0

        try AudioObjectGetPropertyDataSize(self, &address, 0, nil, &byteSize)
            .check("Groesse von \(selector.fourCharCode) auf Objekt \(self)")

        let capacity = Int(byteSize) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }

        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        try AudioObjectGetPropertyData(self, &address, 0, nil, &byteSize, buffer.baseAddress!)
            .check("Lesen von \(selector.fourCharCode) auf Objekt \(self)")

        // byteSize wird vom Aufruf auf die tatsaechlich geschriebene Menge korrigiert.
        return Array(buffer.prefix(Int(byteSize) / MemoryLayout<T>.stride))
    }

    /// Liest eine CFString-Property. Core Audio uebergibt die Referenz mit +1,
    /// daher `takeRetainedValue`.
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress.global(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        try withUnsafeMutablePointer(to: &value) { pointer in
            try AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
                .check("Lesen von \(selector.fourCharCode) auf Objekt \(self)")
        }
        guard let value else {
            throw CoreAudioError(status: kAudioHardwareUnknownPropertyError,
                                 operation: "String \(selector.fourCharCode) war leer")
        }
        return value as String
    }

    /// Existiert die Property auf diesem Objekt ueberhaupt?
    func hasProperty(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress.global(selector)
        return AudioObjectHasProperty(self, &address)
    }

    // MARK: - Beobachten

    /// Registriert einen Listener und liefert ein Handle, das beim Deinit deregistriert.
    func observe(
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws -> PropertyObservation {
        try PropertyObservation(objectID: self, selector: selector, queue: queue, handler: handler)
    }
}

/// Haelt eine Core-Audio-Property-Listener-Registrierung am Leben und raeumt sie auf.
final class PropertyObservation {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) throws {
        self.objectID = objectID
        self.address = .global(selector)
        self.queue = queue
        self.block = { _, _ in handler() }

        try AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block)
            .check("Listener fuer \(selector.fourCharCode) registrieren")
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

extension AudioObjectPropertySelector {
    var fourCharCode: String { OSStatus(bitPattern: self).fourCharCode }
}
