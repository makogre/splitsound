import AudioToolbox
import CoreAudio
import XCTest

@testable import SplitSound

/// Verifies the channel mapping in the realtime render path using synthetic buffers.
///
/// Real audio hardware is unsuitable here: the output cannot be measured back,
/// and a mono or multichannel device is not always at hand.
final class RenderTests: XCTestCase {
    /// Calls `ProcessTap.render` with one input buffer and returns whatever
    /// ends up in the output buffer.
    private func render(
        inChannels: UInt32,
        inSamples: [Float],
        outChannels: UInt32,
        outSampleCount: Int,
        gain: Float
    ) -> (output: [Float], peak: Float) {
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: inSamples.count)
        inData.initialize(from: inSamples, count: inSamples.count)
        defer { inData.deallocate() }

        // Prefilled with a conspicuous value, so untouched regions that should
        // have been written stand out.
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: outSampleCount)
        outData.initialize(repeating: -99, count: outSampleCount)
        defer { outData.deallocate() }

        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inList.unsafeMutablePointer) }
        inList[0] = AudioBuffer(
            mNumberChannels: inChannels,
            mDataByteSize: UInt32(inSamples.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(inData)
        )

        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outList.unsafeMutablePointer) }
        outList[0] = AudioBuffer(
            mNumberChannels: outChannels,
            mDataByteSize: UInt32(outSampleCount * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(outData)
        )

        let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        peak.initialize(to: 0)
        defer { peak.deallocate() }

        ProcessTap.render(
            input: inList.unsafePointer,
            output: outList.unsafeMutablePointer,
            gain: gain,
            peak: peak
        )
        return ((0..<outSampleCount).map { outData[$0] }, peak.pointee)
    }

    func testStereoToStereoAppliesGain() {
        // Two frames: (1, -1) and (0.5, -0.5)
        let result = render(inChannels: 2, inSamples: [1, -1, 0.5, -0.5],
                            outChannels: 2, outSampleCount: 4, gain: 0.5)
        XCTAssertEqual(result.output, [0.5, -0.5, 0.25, -0.25])
    }

    func testPeakReportsInputLevelBeforeGain() {
        // The level meter should show how loud the app *plays* — not how loud
        // we let it through.
        let result = render(inChannels: 2, inSamples: [1, -1, 0.5, -0.5],
                            outChannels: 2, outSampleCount: 4, gain: 0.5)
        XCTAssertEqual(result.peak, 1.0, accuracy: 0.0001)
    }

    func testStereoToMonoMixesInsteadOfDroppingChannels() {
        // Frame 1: (1, 0) -> 0.5    Frame 2: (0.4, 0.6) -> 0.5
        let result = render(inChannels: 2, inSamples: [1, 0, 0.4, 0.6],
                            outChannels: 1, outSampleCount: 2, gain: 1.0)
        XCTAssertEqual(result.output[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.output[1], 0.5, accuracy: 0.0001)
    }

    func testMonoToStereoFillsBothChannels() {
        let result = render(inChannels: 1, inSamples: [0.8, -0.4],
                            outChannels: 2, outSampleCount: 4, gain: 1.0)
        XCTAssertEqual(result.output, [0.8, 0.8, -0.4, -0.4])
    }

    func testShortInputSilencesRemainderOfOutput() {
        // Otherwise stale buffer content would remain and be audible as a click.
        let result = render(inChannels: 2, inSamples: [1, 1],
                            outChannels: 2, outSampleCount: 6, gain: 1.0)
        XCTAssertEqual(result.output, [1, 1, 0, 0, 0, 0])
    }

    func testZeroGainProducesSilence() {
        let result = render(inChannels: 2, inSamples: [1, -1, 1, -1],
                            outChannels: 2, outSampleCount: 4, gain: 0)
        XCTAssertEqual(result.output, [0, 0, 0, 0])
    }

    func testMissingInputBufferSilencesOutput() {
        // No input present: the output must be cleared rather than left with
        // the prefilled garbage.
        let outData = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        outData.initialize(repeating: -99, count: 4)
        defer { outData.deallocate() }

        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(inList.unsafeMutablePointer) }
        inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)

        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outList.unsafeMutablePointer) }
        outList[0] = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: UInt32(4 * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(outData)
        )

        let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        peak.initialize(to: 0)
        defer { peak.deallocate() }

        ProcessTap.render(input: inList.unsafePointer, output: outList.unsafeMutablePointer,
                          gain: 1.0, peak: peak)

        XCTAssertEqual((0..<4).map { outData[$0] }, [0, 0, 0, 0])
    }
}
