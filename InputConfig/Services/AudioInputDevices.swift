import Foundation
import CoreAudio

/// Enumerates the Mac's audio INPUT devices (built-in mic, headsets, interfaces, iPhone
/// Continuity mics) so the person can pick which one voice phrases listen to, instead of being stuck
/// with the system default. Pure CoreAudio; no permissions beyond the microphone access voice
/// phrases already need. From YapToText (Audio/AudioInputDevices.swift).
enum AudioInputDevices {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        /// Stable identifier that survives relaunches and re-plugs; what we persist in settings.
        let uid: String
        let name: String
    }

    /// Every device that can capture audio, in system order.
    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func device(forUID uid: String) -> Device? {
        all().first { $0.uid == uid }
    }

    /// The UID of the system's current default input device, or nil if there is none.
    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

/// Mutes and unmutes a microphone for the microphone System Functions. A
/// device with a mute switch of its own is muted with it; one with only an
/// input volume is turned down to zero and put back to where it was.
enum MicrophoneSwitch {
    /// How an output's text names its microphone: this prefix, then the
    /// device's UID. Anything else, or nothing, is the microphone the Mac
    /// is using when the row fires.
    static let prefix = "mic:"

    static func uid(from parameter: String?) -> String? {
        guard let parameter, parameter.hasPrefix(prefix), parameter.count > prefix.count else { return nil }
        return String(parameter.dropFirst(prefix.count))
    }

    static func parameter(forUID uid: String) -> String? {
        uid.isEmpty ? nil : prefix + uid
    }

    /// How a device can be muted, from what it offers.
    enum Way: Equatable { case muteSwitch, volume, none }

    static func way(muteSettable: Bool, volumeSettable: Bool) -> Way {
        muteSettable ? .muteSwitch : volumeSettable ? .volume : .none
    }

    static func deviceID(_ parameter: String?) -> AudioDeviceID? {
        guard let wanted = uid(from: parameter) ?? AudioInputDevices.defaultInputUID() else { return nil }
        return AudioInputDevices.device(forUID: wanted)?.id
    }

    static func toggle(_ parameter: String?) {
        #if DEBUG
        if TestCapture.active { TestCapture.note("microphone toggle \(uid(from: parameter) ?? "default")"); return }
        #endif
        guard let id = deviceID(parameter), let muted = isMuted(id), setMuted(!muted, id) else { return skipped() }
    }

    static func set(muted: Bool, _ parameter: String?) {
        #if DEBUG
        if TestCapture.active { TestCapture.note("microphone \(muted ? "muted" : "live") \(uid(from: parameter) ?? "default")"); return }
        #endif
        guard let id = deviceID(parameter), setMuted(muted, id) else { return skipped() }
    }

    private static func skipped() {
        ActivityLog.shared.warning("Outputs", String(localized: "Microphone output skipped: the microphone is not connected or cannot be muted"))
    }

    static func way(_ id: AudioDeviceID) -> Way {
        way(muteSettable: settable(id, kAudioDevicePropertyMute, 0), volumeSettable: !volumeElements(id).isEmpty)
    }

    /// Nil for a device that can be neither muted nor turned down.
    static func isMuted(_ id: AudioDeviceID) -> Bool? {
        switch way(id) {
        case .muteSwitch:
            var address = inputAddress(kAudioDevicePropertyMute, 0)
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &muted) == noErr else { return nil }
            return muted != 0
        case .volume:
            return volumeElements(id).allSatisfy { (volume(id, $0) ?? 1) <= 0 }
        case .none:
            return nil
        }
    }

    @discardableResult
    static func setMuted(_ muted: Bool, _ id: AudioDeviceID) -> Bool {
        switch way(id) {
        case .muteSwitch:
            var address = inputAddress(kAudioDevicePropertyMute, 0)
            var value: UInt32 = muted ? 1 : 0
            return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        case .volume:
            let elements = volumeElements(id)
            let key = "InputConfig.microphoneVolumeBeforeMute"
            let name = AudioInputDevices.all().first { $0.id == id }?.uid ?? String(id)
            var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
            var level: Float32 = 0
            if muted {
                let now = elements.compactMap { volume(id, $0) }.max() ?? 0
                if now > 0 { saved[name] = Double(now); UserDefaults.standard.set(saved, forKey: key) }
            } else {
                level = Float32(saved[name] ?? 0.75)
            }
            var done = true
            for element in elements {
                var address = inputAddress(kAudioDevicePropertyVolumeScalar, element)
                var value = level
                if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) != noErr { done = false }
            }
            return done
        case .none:
            return false
        }
    }

    private static func inputAddress(_ selector: AudioObjectPropertySelector, _ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
    }

    private static func settable(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Bool {
        var address = inputAddress(selector, element)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var can: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &can) == noErr && can.boolValue
    }

    /// The input volume controls a device has: the main one, or each
    /// channel's own where there is no main one.
    private static func volumeElements(_ id: AudioDeviceID) -> [UInt32] {
        if settable(id, kAudioDevicePropertyVolumeScalar, 0) { return [0] }
        return (1...8).filter { settable(id, kAudioDevicePropertyVolumeScalar, UInt32($0)) }.map(UInt32.init)
    }

    private static func volume(_ id: AudioDeviceID, _ element: UInt32) -> Float32? {
        var address = inputAddress(kAudioDevicePropertyVolumeScalar, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
