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
    /// Form des Eingangs im letzten Durchlauf — zur Fehlersuche, wenn kein Ton ankommt.
    private let inputShapeStorage: UnsafeMutablePointer<InputShape>

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let tapUUID = UUID()

    private let log = Logger(subsystem: "com.maxgrell.SplitSound", category: "ProcessTap")

    var gain: Float {
        get { gainStorage.pointee }
        set { gainStorage.pointee = max(0, min(newValue, 1)) }
    }

    /// Momentaufnahme der Eingangspuffer, wie der IOProc sie zuletzt gesehen hat.
    struct InputShape {
        var bufferCount: UInt32 = 0
        var channels: UInt32 = 0
        var byteSize: UInt32 = 0
        var outputBufferCount: UInt32 = 0
        var outputChannels: UInt32 = 0
        var outputByteSize: UInt32 = 0
    }

    var inputShape: InputShape { inputShapeStorage.pointee }

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
        self.inputShapeStorage = .allocate(capacity: 1)
        self.inputShapeStorage.initialize(to: InputShape())
    }

    deinit {
        invalidate()
        gainStorage.deinitialize(count: 1)
        gainStorage.deallocate()
        peakStorage.deinitialize(count: 1)
        peakStorage.deallocate()
        renderCountStorage.deinitialize(count: 1)
        renderCountStorage.deallocate()
        inputShapeStorage.deinitialize(count: 1)
        inputShapeStorage.deallocate()
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
        let shapePointer = inputShapeStorage

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) {
            _, inputData, _, outputData, _ in
            countPointer.pointee &+= 1
            Self.render(
                input: inputData,
                output: outputData,
                gain: gainPointer.pointee,
                peak: peakPointer,
                shape: shapePointer
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
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float,
        peak: UnsafeMutablePointer<Float>,
        shape: UnsafeMutablePointer<InputShape>
    ) {
        var blockPeak: Float = 0
        defer { peak.pointee = blockPeak }

        let inputList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputList = UnsafeMutableAudioBufferListPointer(output)

        shape.pointee = InputShape(
            bufferCount: UInt32(inputList.count),
            channels: inputList.count > 0 ? inputList[0].mNumberChannels : 0,
            byteSize: inputList.count > 0 ? inputList[0].mDataByteSize : 0,
            outputBufferCount: UInt32(outputList.count),
            outputChannels: outputList.count > 0 ? outputList[0].mNumberChannels : 0,
            outputByteSize: outputList.count > 0 ? outputList[0].mDataByteSize : 0
        )

        for index in 0..<outputList.count {
            let outBuffer = outputList[index]
            guard let outData = outBuffer.mData else { continue }

            // Kein passender Eingang: Stille schreiben, sonst rauscht alter
            // Pufferinhalt durch.
            guard index < inputList.count,
                  let inData = inputList[index].mData,
                  inputList[index].mNumberChannels == outBuffer.mNumberChannels
            else {
                memset(outData, 0, Int(outBuffer.mDataByteSize))
                continue
            }

            let byteCount = min(inputList[index].mDataByteSize, outBuffer.mDataByteSize)
            let sampleCount = Int(byteCount) / MemoryLayout<Float>.size

            let source = inData.assumingMemoryBound(to: Float.self)
            let destination = outData.assumingMemoryBound(to: Float.self)

            for sample in 0..<sampleCount {
                let value = source[sample]
                let magnitude = value < 0 ? -value : value
                if magnitude > blockPeak { blockPeak = magnitude }
                destination[sample] = value * gain
            }

            // Falls der Ausgang groesser ist als der Eingang: Rest stillegen.
            if outBuffer.mDataByteSize > byteCount {
                memset(outData + Int(byteCount), 0, Int(outBuffer.mDataByteSize - byteCount))
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
