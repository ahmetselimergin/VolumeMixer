import CoreAudio
import Foundation

/// Mutes a group of processes with a Core Audio process tap and replays their
/// audio on the output device at an adjustable gain.
final class AppTap {
    let processObjects: [AudioObjectID]
    let outputDevice: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    // [0] = target gain (written by UI), [1] = current gain (owned by the audio thread)
    private let gains = UnsafeMutablePointer<Float>.allocate(capacity: 2)

    var gain: Float {
        get { gains[0] }
        set { gains[0] = max(0, min(1, newValue)) }
    }

    init(processObjects: [AudioObjectID], outputDevice: AudioObjectID, gain: Float) throws {
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        gains[0] = gain
        gains[1] = gain

        do {
            try start()
        } catch {
            teardown()
            gains.deallocate()
            throw error
        }
    }

    deinit {
        teardown()
        gains.deallocate()
    }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "VolumeMixer"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap")

        guard let outputUID = outputDevice.readString(kAudioDevicePropertyDeviceUID) else {
            throw CoreAudioError(status: -1, operation: "Output device not found")
        }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Creating aggregate device")

        // The aggregate's input streams are the output device's own inputs (e.g. AirPods mic)
        // followed by the tap. Skip the device inputs so we never touch a microphone.
        let deviceInputStreams = outputDevice.readObjectList(kAudioDevicePropertyStreams,
                                                             scope: kAudioObjectPropertyScopeInput).count
        let gains = self.gains
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            render(input: input, output: output, skipInputBuffers: deviceInputStreams, gains: gains)
        }, "Creating IOProc")

        disableInputStreams(count: deviceInputStreams)
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio")
    }

    /// Tells the HAL this IOProc doesn't use the device's own input streams, so it doesn't open them.
    private func disableInputStreams(count: Int) {
        guard count > 0, let ioProcID else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr else { return }
        let flags = (raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
            .assumingMemoryBound(to: UInt32.self)
        for i in 0..<min(count, Int(usage.pointee.mNumberStreams)) { flags[i] = 0 }
        AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, size, raw)
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

/// Real-time callback: copy tap audio to the output with a gain ramp. No allocation, no locks.
private func render(input: UnsafePointer<AudioBufferList>,
                    output: UnsafeMutablePointer<AudioBufferList>,
                    skipInputBuffers: Int,
                    gains: UnsafeMutablePointer<Float>) {
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outList = UnsafeMutableAudioBufferListPointer(output)

    for buffer in outList {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }

    var inChannels = 0
    for i in skipInputBuffers..<max(skipInputBuffers, inList.count) {
        inChannels += Int(inList[i].mNumberChannels)
    }
    let target = gains[0]
    let startGain = gains[1]
    gains[1] = target
    guard inChannels > 0 else { return }

    var outChannelBase = 0
    for outBuffer in outList {
        let outCh = Int(outBuffer.mNumberChannels)
        defer { outChannelBase += outCh }
        guard outCh > 0, let out = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let frames = Int(outBuffer.mDataByteSize) / (MemoryLayout<Float>.size * outCh)
        guard frames > 0 else { continue }
        let step = (target - startGain) / Float(frames)

        for c in 0..<outCh {
            // Map output channel → input channel (wraps, so stereo tap fills multichannel outputs).
            var srcChannel = (outChannelBase + c) % inChannels
            var source: AudioBuffer?
            for i in skipInputBuffers..<inList.count {
                let n = Int(inList[i].mNumberChannels)
                if srcChannel < n { source = inList[i]; break }
                srcChannel -= n
            }
            guard let src = source, let inData = src.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let inCh = Int(src.mNumberChannels)
            let count = min(frames, Int(src.mDataByteSize) / (MemoryLayout<Float>.size * inCh))
            var g = startGain
            for f in 0..<count {
                out[f * outCh + c] = inData[f * inCh + srcChannel] * g
                g += step
            }
        }
    }
}
