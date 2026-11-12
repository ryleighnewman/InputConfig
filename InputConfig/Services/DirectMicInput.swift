import AVFoundation
import AudioToolbox
import CoreAudio

/// Microphone capture straight from a CoreAudio HAL output unit, for a
/// microphone chosen in Settings. From YapToText (Audio/DirectInput.swift).
///
/// AVAudioEngine's input node follows the system default input. It accepts
/// `kAudioOutputUnitProperty_CurrentDevice`, but keeps the default's format
/// and goes back to the default device at its first configuration change
/// (measured in YapToText, Sep and Nov 2026). A bare HALOutput unit binds to
/// the device it is told, reports that device's real format, and stays on it.
final class DirectMicInput: @unchecked Sendable {
    private var unit: AudioUnit?
    private(set) var format: AVAudioFormat?
    private(set) var deviceUID: String?
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    private var scratch: AVAudioPCMBuffer?
    /// Frames gathered into 100 ms chunks, the size AVAudioEngine's tap hands
    /// over; the HAL calls back every 512 frames or so.
    private var chunk: AVAudioPCMBuffer?
    private var chunkFrames: UInt32 = 4800
    private let frames: UInt32 = 4096
    /// Buffers handed on and the loudest sample since start, for the
    /// debug voice readout.
    private let statsLock = NSLock()
    private var delivered = 0
    private var loudest: Float = 0
    var stats: (buffers: Int, peak: Float) { statsLock.lock(); defer { statsLock.unlock() }; return (delivered, loudest) }

    /// Binds to the device, reads its hardware format and starts pulling.
    /// Each 100 ms reaches `sink` as a buffer of its own, on the HAL's thread.
    func start(deviceID: AudioDeviceID, deviceUID: String, sink: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw DirectMicInputError.status(-1, "no HAL output unit") }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "instance")
        guard let au else { throw DirectMicInputError.status(-1, "no instance") }
        unit = au
        var one: UInt32 = 1, zero: UInt32 = 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")
        var dev = deviceID
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4), "set device")
        var hw = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "read hardware format")
        guard hw.mSampleRate > 0, hw.mChannelsPerFrame > 0 else { throw DirectMicInputError.status(-1, "device reports no format") }
        // Mono: speech recognition wants one channel, and a three-capsule
        // MacBook microphone would otherwise hand it three.
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate, channels: 1, interleaved: false) else {
            throw DirectMicInputError.status(-1, "client format")
        }
        var client = fmt.streamDescription.pointee
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set client format")
        var maxFrames = frames
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, 4)
        format = fmt
        self.deviceUID = deviceUID
        self.sink = sink
        scratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames * 2)
        chunkFrames = UInt32(max(1024, Int(fmt.sampleRate * 0.1)))
        chunk = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkFrames)
        chunk?.frameLength = 0
        var cb = AURenderCallbackStruct(inputProc: DirectMicInput.inputProc,
                                        inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try check(AudioUnitInitialize(au), "initialize")
        try check(AudioOutputUnitStart(au), "start")
    }

    var isRunning: Bool { unit != nil }

    func stop() {
        guard let au = unit else { return }
        unit = nil
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        sink = nil
        scratch = nil
        chunk = nil
    }

    deinit { stop() }

    /// Pulls what CoreAudio just captured and hands each complete 100 ms on
    /// as a copy, since the recognizer keeps the buffers it is given.
    private static let inputProc: AURenderCallback = { refCon, flags, timestamp, bus, frameCount, _ in
        let me = Unmanaged<DirectMicInput>.fromOpaque(refCon).takeUnretainedValue()
        guard let au = me.unit, let buf = me.scratch, frameCount <= buf.frameCapacity, let sink = me.sink else { return noErr }
        buf.frameLength = frameCount
        let status = AudioUnitRender(au, flags, timestamp, bus, frameCount, buf.mutableAudioBufferList)
        guard status == noErr, frameCount > 0, let chunk = me.chunk else { return status }
        var offset: UInt32 = 0
        while offset < frameCount {
            let room = chunk.frameCapacity - chunk.frameLength
            let take = min(room, frameCount - offset)
            if let src = buf.floatChannelData, let dst = chunk.floatChannelData {
                memcpy(dst[0] + Int(chunk.frameLength), src[0] + Int(offset), Int(take) * MemoryLayout<Float>.size)
            }
            chunk.frameLength += take
            offset += take
            if chunk.frameLength == chunk.frameCapacity {
                if let copy = AVAudioPCMBuffer(pcmFormat: chunk.format, frameCapacity: chunk.frameLength),
                   let src = chunk.floatChannelData, let dst = copy.floatChannelData {
                    copy.frameLength = chunk.frameLength
                    memcpy(dst[0], src[0], Int(chunk.frameLength) * MemoryLayout<Float>.size)
                    var p: Float = 0
                    for i in 0..<Int(copy.frameLength) { p = max(p, abs(dst[0][i])) }
                    me.statsLock.lock(); me.delivered += 1; me.loudest = max(me.loudest, p); me.statsLock.unlock()
                    sink(copy)
                }
                chunk.frameLength = 0
            }
        }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { stop(); throw DirectMicInputError.status(status, what) }
    }
}

enum DirectMicInputError: Error, CustomStringConvertible {
    case status(OSStatus, String)
    var description: String {
        switch self { case let .status(s, what): return "microphone: \(what) failed (\(s))" }
    }
}
