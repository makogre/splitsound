import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Controls the volume of a *single* app by muting its original output and
/// emitting a scaled copy instead.
///
/// How it works:
///  1. Place a process tap on the process with `muteBehavior = .mutedWhenTapped`.
///     That kills the app's direct path to the speakers; its samples arrive
///     on our input instead.
///  2. Build a private aggregate device from [real output device + this tap].
///  3. An IOProc reads the tap input, multiplies by the gain, and writes the
///     result to the output device.
///
/// Deliberate choice: one aggregate device *per app* rather than a shared one.
/// With a shared device you would have to map input buffers to taps, which
/// depends on sub-device ordering and fails silently when it is wrong. Per app
/// there is exactly one input — unambiguous.
final class ProcessTap {
    let processObjectID: AudioObjectID
    private(set) var isActive = false

    /// Read by the realtime IOProc, written by the main thread.
    /// Deliberately a raw pointer: the IOProc must not lock or call into the
    /// Swift runtime. Four-byte-aligned Float accesses are atomic on
    /// arm64/x86_64.
    private let gainStorage: UnsafeMutablePointer<Float>

    /// Peak level of the last render pass, before gain is applied. Feeds the
    /// level meter — and proves during testing that the realtime callback is
    /// actually receiving samples.
    private let peakStorage: UnsafeMutablePointer<Float>
    /// Counts render invocations, making it visible whether the IOProc runs at all.
    private let renderCountStorage: UnsafeMutablePointer<UInt64>

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let tapUUID = UUID()

    private let log = Logger(subsystem: "com.maxgrell.SplitSound", category: "ProcessTap")

    var gain: Float {
        get { gainStorage.pointee }
        set { gainStorage.pointee = max(0, min(newValue, 1)) }
    }

    /// Peak level (0…1) of the most recently rendered block.
    var peakLevel: Float { peakStorage.pointee }

    /// Number of render invocations so far.
    var renderCount: UInt64 { renderCountStorage.pointee }

    init(processObjectID: AudioObjectID, gain: Float = 1.0) {
        self.processObjectID = processObjectID
        self.gainStorage = .allocate(capacity: 1)
        self.gainStorage.initialize(to: max(0, min(gain, 1)))
        self.peakStorage = .allocate(capacity: 1)
        self.peakStorage.initialize(to: 0)
        self.renderCountStorage = .allocate(capacity: 1)
        self.renderCountStorage.initialize(to: 0)
    }

    deinit {
        invalidate()
        gainStorage.deinitialize(count: 1)
        gainStorage.deallocate()
        peakStorage.deinitialize(count: 1)
        peakStorage.deallocate()
        renderCountStorage.deinitialize(count: 1)
        renderCountStorage.deallocate()
    }

    // MARK: - Lifecycle

    func activate() throws {
        guard !isActive else { return }

        try createTap()
        let outputUID = try Self.defaultOutputDeviceUID()
        try createAggregateDevice(outputUID: outputUID)
        try startIOProc()

        isActive = true
        log.info("Tap active for process \(self.processObjectID)")
    }

    func invalidate() {
        guard isActive || tapID.isValid || aggregateID.isValid else { return }

        if let ioProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        isActive = false
    }

    // MARK: - Setup

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = tapUUID
        description.name = "SplitSound Tap \(processObjectID)"
        // Only we can see the tap; it appears in no device list.
        description.isPrivate = true
        // The original audio goes silent while we tap — we supply the replacement.
        description.muteBehavior = .mutedWhenTapped

        try AudioHardwareCreateProcessTap(description, &tapID)
            .check("Creating process tap for process \(processObjectID)")
    }

    private func createAggregateDevice(outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SplitSound \(processObjectID)",
            kAudioAggregateDeviceUIDKey: "com.maxgrell.SplitSound.agg.\(tapUUID.uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        try AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
            .check("Creating aggregate device for process \(processObjectID)")
    }

    private func startIOProc() throws {
        let gainPointer = gainStorage
        let peakPointer = peakStorage
        let countPointer = renderCountStorage

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            _, inputData, _, outputData, _ in
            countPointer.pointee &+= 1
            Self.render(
                input: inputData,
                output: outputData,
                gain: gainPointer.pointee,
                peak: peakPointer
            )
        }
        try status.check("Creating IOProc")

        guard let procID else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "IOProc was nil")
        }
        ioProcID = procID

        try AudioDeviceStart(aggregateID, procID).check("Starting aggregate device")
    }

    // MARK: - Realtime

    /// Runs on the audio realtime thread. No allocation, no locking, no Swift
    /// runtime calls — pointer arithmetic only.
    ///
    /// Not `private` so the channel mapping can be verified with synthetic
    /// buffers, without needing real audio hardware.
    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float,
        peak: UnsafeMutablePointer<Float>
    ) {
        var blockPeak: Float = 0
        defer { peak.pointee = blockPeak }

        let inputList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        for index in 0..<outputList.count {
            let outBuffer = outputList[index]
            guard let outData = outBuffer.mData else { continue }

            // No matching input: write silence, otherwise stale buffer content
            // leaks through as noise.
            guard index < inputList.count,
                  let inData = inputList[index].mData,
                  inputList[index].mNumberChannels > 0,
                  outBuffer.mNumberChannels > 0
            else {
                memset(outData, 0, Int(outBuffer.mDataByteSize))
                continue
            }

            let source = inData.assumingMemoryBound(to: Float.self)
            let destination = outData.assumingMemoryBound(to: Float.self)
            let inChannels = Int(inputList[index].mNumberChannels)
            let outChannels = Int(outBuffer.mNumberChannels)

            let inFrames = Int(inputList[index].mDataByteSize)
                / (MemoryLayout<Float>.size * inChannels)
            let outFrames = Int(outBuffer.mDataByteSize)
                / (MemoryLayout<Float>.size * outChannels)
            let frames = min(inFrames, outFrames)

            if inChannels == outChannels {
                // Common case (stereo to stereo): straight copy.
                for sample in 0..<(frames * inChannels) {
                    let value = source[sample]
                    let magnitude = value < 0 ? -value : value
                    if magnitude > blockPeak { blockPeak = magnitude }
                    destination[sample] = value * gain
                }
            } else if outChannels < inChannels {
                // Output device has fewer channels (mono, for instance): mix
                // down rather than discarding the surplus channels.
                let scale = gain / Float(inChannels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<inChannels {
                        let value = source[frame * inChannels + channel]
                        let magnitude = value < 0 ? -value : value
                        if magnitude > blockPeak { blockPeak = magnitude }
                        sum += value
                    }
                    let mixed = sum * scale
                    for channel in 0..<outChannels {
                        destination[frame * outChannels + channel] = mixed
                    }
                }
            } else {
                // More output than input channels: repeat cyclically, so a mono
                // source is audible on every channel.
                for frame in 0..<frames {
                    for channel in 0..<outChannels {
                        let value = source[frame * inChannels + (channel % inChannels)]
                        let magnitude = value < 0 ? -value : value
                        if magnitude > blockPeak { blockPeak = magnitude }
                        destination[frame * outChannels + channel] = value * gain
                    }
                }
            }

            // If the input supplies fewer frames than the output holds, the
            // remainder would otherwise keep its stale contents.
            let writtenBytes = frames * outChannels * MemoryLayout<Float>.size
            if Int(outBuffer.mDataByteSize) > writtenBytes {
                memset(outData + writtenBytes, 0, Int(outBuffer.mDataByteSize) - writtenBytes)
            }
        }
    }

    // MARK: - Helpers

    static func defaultOutputDeviceUID() throws -> String {
        let deviceID: AudioObjectID = try AudioObjectID.system
            .read(kAudioHardwarePropertyDefaultOutputDevice)
        return try deviceID.readString(kAudioDevicePropertyDeviceUID)
    }
}
