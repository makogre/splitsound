import CoreAudio
import Foundation

/// An error from the Core Audio C API, carrying the readable four-character code.
struct CoreAudioError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "\(operation) failed: \(status.fourCharCode) (\(status))"
    }
}

extension OSStatus {
    /// Core Audio usually encodes errors as four-character codes ('!obj', 'nope', …).
    /// Non-printable codes are rendered as a number.
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

    /// Throws unless the status indicates success.
    func check(_ operation: String) throws {
        guard self == noErr else { throw CoreAudioError(status: self, operation: operation) }
    }
}

extension AudioObjectPropertyAddress {
    /// Shorthand for the overwhelmingly common case: global scope, main element.
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

    // MARK: - Reading

    /// Reads a fixed-size property (Int32, UInt32, Bool32, structs, …).
    func read<T>(_ selector: AudioObjectPropertySelector, as type: T.Type = T.self) throws -> T {
        var address = AudioObjectPropertyAddress.global(selector)
        var size = UInt32(MemoryLayout<T>.size)

        let value = try withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer -> T in
            let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
            try status.check("Reading \(selector.fourCharCode) on object \(self)")
            return buffer.baseAddress!.pointee
        }
        return value
    }

    /// Reads a variable-length property as an array (object lists, for example).
    func readArray<T>(_ selector: AudioObjectPropertySelector, of type: T.Type = T.self) throws -> [T] {
        var address = AudioObjectPropertyAddress.global(selector)
        var byteSize: UInt32 = 0

        try AudioObjectGetPropertyDataSize(self, &address, 0, nil, &byteSize)
            .check("Sizing \(selector.fourCharCode) on object \(self)")

        let capacity = Int(byteSize) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }

        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        try AudioObjectGetPropertyData(self, &address, 0, nil, &byteSize, buffer.baseAddress!)
            .check("Reading \(selector.fourCharCode) on object \(self)")

        // The call corrects byteSize to the amount actually written.
        return Array(buffer.prefix(Int(byteSize) / MemoryLayout<T>.stride))
    }

    /// Reads a CFString property. Core Audio hands the reference over at +1,
    /// hence `takeRetainedValue` semantics.
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress.global(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?

        try withUnsafeMutablePointer(to: &value) { pointer in
            try AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
                .check("Reading \(selector.fourCharCode) on object \(self)")
        }
        guard let value else {
            throw CoreAudioError(status: kAudioHardwareUnknownPropertyError,
                                 operation: "String \(selector.fourCharCode) was empty")
        }
        return value as String
    }

    /// Does this object expose the property at all?
    func hasProperty(_ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress.global(selector)
        return AudioObjectHasProperty(self, &address)
    }

    // MARK: - Observing

    /// Registers a listener and returns a handle that deregisters on deinit.
    func observe(
        _ selector: AudioObjectPropertySelector,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws -> PropertyObservation {
        try PropertyObservation(objectID: self, selector: selector, queue: queue, handler: handler)
    }
}

/// Keeps a Core Audio property listener registration alive and tears it down.
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
            .check("Registering listener for \(selector.fourCharCode)")
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }
}

extension AudioObjectPropertySelector {
    var fourCharCode: String { OSStatus(bitPattern: self).fourCharCode }
}
