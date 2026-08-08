import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Regelt die Lautstaerke *einer* App, indem der Originalton stummgeschaltet
/// und eine selbst skalierte Kopie ausgegeben wird.
///
/// Ablauf:
///  1. Process Tap auf den Prozess legen, `muteBehavior = .mutedWhenTapped`.
///     Damit ist der direkte Weg der App zum Lautsprecher tot, wir bekommen
///     die Samples stattdessen als Eingang.
///  2. Privates Aggregate Device bauen aus [echtes Ausgabegeraet + dieser Tap].
///  3. Ein IOProc liest den Tap-Eingang, multipliziert mit dem Gain und
///     schreibt das Ergebnis auf das Ausgabegeraet.
///
/// Bewusste Entscheidung: ein Aggregate Device *pro App* statt eines
/// gemeinsamen. Bei einem gemeinsamen Geraet muesste man die Eingangspuffer
/// den Taps zuordnen, was von der Reihenfolge der Sub-Devices abhaengt und
/// leicht still danebengeht. Pro App gibt es genau einen Eingang — eindeutig.
final class ProcessTap {
    let processObjectID: AudioObjectID
    private(set) var isActive = false

    /// Wird vom Realtime-IOProc gelesen und vom Main Thread geschrieben.
    /// Bewusst ein roher Zeiger: im IOProc darf nicht gesperrt oder
    /// Swift-Runtime-Code aufgerufen werden. 4-Byte-aligned Float-Zugriffe
    /// sind auf arm64/x86_64 atomar.
    private let gainStorage: UnsafeMutablePointer<Float>

    /// Spitzenpegel des letzten Render-Durchlaufs, vor Anwendung des Gains.
    /// Speist die Pegelanzeige im Mixer — und belegt beim Testen, dass der
    /// Realtime-Callback wirklich Samples bekommt.
    private let peakStorage: UnsafeMutablePointer<Float>
    /// Zaehlt Render-Aufrufe, damit sichtbar ist, ob der IOProc ueberhaupt laeuft.
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

    /// Spitzenpegel (0…1) des zuletzt gerenderten Blocks.
    var peakLevel: Float { peakStorage.pointee }

    /// Anzahl bisheriger Render-Aufrufe.
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

    // MARK: - Lebenszyklus

    func activate() throws {
        guard !isActive else { return }

        try createTap()
        let outputUID = try Self.defaultOutputDeviceUID()
        try createAggregateDevice(outputUID: outputUID)
        try startIOProc()

        isActive = true
        log.info("Tap aktiv fuer Prozess \(self.processObjectID)")
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

    // MARK: - Aufbau

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = tapUUID
        description.name = "SplitSound Tap \(processObjectID)"
        // Nur wir sehen den Tap; er taucht in keiner Geraeteliste auf.
        description.isPrivate = true
        // Der Originalton verstummt, solange wir tappen — wir liefern den Ersatz.
        description.muteBehavior = .mutedWhenTapped

        try AudioHardwareCreateProcessTap(description, &tapID)
            .check("Process Tap fuer Prozess \(processObjectID) anlegen")
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
            .check("Aggregate Device fuer Prozess \(processObjectID) anlegen")
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
        try status.check("IOProc anlegen")

        guard let procID else {
            throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "IOProc war nil")
        }
        ioProcID = procID

        try AudioDeviceStart(aggregateID, procID).check("Aggregate Device starten")
    }

    // MARK: - Realtime

    /// Laeuft auf dem Audio-Realtime-Thread. Kein Allozieren, kein Sperren,
    /// keine Swift-Runtime-Aufrufe — nur Zeigerarithmetik.
    ///
    /// Nicht `private`, damit die Kanalzuordnung mit synthetischen Puffern
    /// geprueft werden kann, ohne echte Audiohardware zu brauchen.
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

            // Kein passender Eingang: Stille schreiben, sonst rauscht alter
            // Pufferinhalt durch.
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
                // Regelfall (Stereo auf Stereo): flach durchkopieren.
                for sample in 0..<(frames * inChannels) {
                    let value = source[sample]
                    let magnitude = value < 0 ? -value : value
                    if magnitude > blockPeak { blockPeak = magnitude }
                    destination[sample] = value * gain
                }
            } else if outChannels < inChannels {
                // Ausgabegeraet hat weniger Kanaele (z. B. mono): mischen,
                // statt die ueberzaehligen Kanaele wegzuwerfen.
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
                // Mehr Ausgabekanaele als Eingangskanaele: reihum wiederholen,
                // damit z. B. Mono-Quellen auf allen Kanaelen zu hoeren sind.
                for frame in 0..<frames {
                    for channel in 0..<outChannels {
                        let value = source[frame * inChannels + (channel % inChannels)]
                        let magnitude = value < 0 ? -value : value
                        if magnitude > blockPeak { blockPeak = magnitude }
                        destination[frame * outChannels + channel] = value * gain
                    }
                }
            }

            // Liefert der Eingang weniger Frames als der Ausgang fasst,
            // bleibt der Rest sonst mit altem Inhalt stehen.
            let writtenBytes = frames * outChannels * MemoryLayout<Float>.size
            if Int(outBuffer.mDataByteSize) > writtenBytes {
                memset(outData + writtenBytes, 0, Int(outBuffer.mDataByteSize) - writtenBytes)
            }
        }
    }

    // MARK: - Hilfen

    static func defaultOutputDeviceUID() throws -> String {
        let deviceID: AudioObjectID = try AudioObjectID.system
            .read(kAudioHardwarePropertyDefaultOutputDevice)
        return try deviceID.readString(kAudioDevicePropertyDeviceUID)
    }
}
