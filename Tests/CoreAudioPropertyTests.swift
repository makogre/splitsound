import CoreAudio
import XCTest

@testable import SplitSound

/// Exercises the property readers against the real Core Audio system object.
///
/// Basic coverage: a reader that returns garbage, throws spuriously, or
/// mis-sizes its buffer fails here.
///
/// What these do *not* catch is the Release-only reader bug described in
/// docs/TECHNICAL.md. That was verified: reintroducing the bug leaves this
/// suite fully green, in Debug and in Release alike, because the test bundle
/// is optimised differently from the app target. The guard for that one is
/// the smoke check in scripts/build-release.sh, which inspects the built app.
final class CoreAudioPropertyTests: XCTestCase {
    func testReadReturnsAPlausibleDefaultOutputDevice() throws {
        let deviceID: AudioObjectID = try AudioObjectID.system
            .read(kAudioHardwarePropertyDefaultOutputDevice)
        XCTAssertTrue(deviceID.isValid, "Default output device should be a valid object")
        XCTAssertNotEqual(deviceID, 0)
    }

    func testReadArrayReturnsTheDeviceList() throws {
        let devices: [AudioObjectID] = try AudioObjectID.system
            .readArray(kAudioHardwarePropertyDevices)
        XCTAssertFalse(devices.isEmpty, "A Mac always has at least one audio device")
        XCTAssertTrue(devices.allSatisfy { $0.isValid },
                      "A garbage entry means the buffer was read incorrectly")
    }

    func testReadArrayAndReadAgreeOnTheDefaultDevice() throws {
        // Cross-check: whatever `read` reports must appear in what
        // `readArray` reports. A miscompiled reader tends to fail exactly one.
        let devices: [AudioObjectID] = try AudioObjectID.system
            .readArray(kAudioHardwarePropertyDevices)
        let defaultDevice: AudioObjectID = try AudioObjectID.system
            .read(kAudioHardwarePropertyDefaultOutputDevice)
        XCTAssertTrue(devices.contains(defaultDevice))
    }

    func testReadStringReturnsADeviceName() throws {
        let deviceID: AudioObjectID = try AudioObjectID.system
            .read(kAudioHardwarePropertyDefaultOutputDevice)
        let name = try deviceID.readString(kAudioObjectPropertyName)
        XCTAssertFalse(name.isEmpty)
    }

    func testProcessListIsReadable() throws {
        // The list that feeds the mixer. Empty here meant an empty mixer.
        let processes: [AudioObjectID] = try AudioObjectID.system
            .readArray(kAudioHardwarePropertyProcessObjectList)
        XCTAssertFalse(processes.isEmpty, "Some process always holds an audio object")
    }

    func testProcessObjectsExposeTheirPID() throws {
        // The exact call that silently failed in Release, leaving every
        // process unusable and the mixer blank.
        let processes: [AudioObjectID] = try AudioObjectID.system
            .readArray(kAudioHardwarePropertyProcessObjectList)
        let readable = processes.filter { (try? $0.read(kAudioProcessPropertyPID) as pid_t) != nil }
        XCTAssertEqual(readable.count, processes.count,
                       "Every process object should report a PID")
    }

    func testMissingPropertyThrowsInsteadOfReturningGarbage() {
        // 'zzzz' does not exist; the reader must report that rather than
        // hand back whatever happened to be in memory.
        let bogus = AudioObjectPropertySelector(0x7A7A_7A7A)
        XCTAssertThrowsError(try AudioObjectID.system.read(bogus) as UInt32)
    }
}
