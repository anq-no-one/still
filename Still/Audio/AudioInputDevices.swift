#if os(macOS)
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }
}

@MainActor
protocol AudioInputDevices: AnyObject {
    var devices: [AudioInputDevice] { get }
    var systemDefault: AudioInputDevice? { get }

    func observe(_ onChange: @escaping @MainActor () -> Void)
}

@MainActor
final class CoreAudioInputDevices: AudioInputDevices {
    private nonisolated static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let watched = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    private var onChange: (@MainActor () -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?

    var devices: [AudioInputDevice] {
        Self.deviceIDs().filter(Self.hasInput).compactMap(Self.device)
    }

    var systemDefault: AudioInputDevice? {
        var id = AudioDeviceID(0)
        guard Self.read(Self.system, kAudioHardwarePropertyDefaultInputDevice, into: &id), id != 0 else { return nil }
        return Self.device(id)
    }

    func observe(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard listener == nil else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, listener)
        }
        self.listener = listener
    }

    isolated deinit {
        guard let listener else { return }
        for selector in Self.watched {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, listener)
        }
    }

    nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { device($0)?.uid == uid }
    }

    nonisolated static func describe(_ id: AudioDeviceID) -> String {
        var transport: UInt32 = 0
        _ = read(id, kAudioDevicePropertyTransportType, into: &transport)
        var rate: Float64 = 0
        _ = read(id, kAudioDevicePropertyNominalSampleRate, into: &rate)
        let kind = withUnsafeBytes(of: transport.bigEndian) { String(decoding: $0, as: UTF8.self) }
        let name = device(id).map { "\($0.name) [\($0.uid)]" } ?? "device \(id)"
        return "\(name) \(kind.trimmingCharacters(in: .controlCharacters)) \(Int(rate))Hz"
    }

    nonisolated static func diagnosticFields() -> [String: String] {
        var input = AudioDeviceID(0)
        var output = AudioDeviceID(0)
        _ = read(system, kAudioHardwarePropertyDefaultInputDevice, into: &input)
        _ = read(system, kAudioHardwarePropertyDefaultOutputDevice, into: &output)
        return [
            "defaultInput": input == 0 ? "none" : describe(input),
            "defaultOutput": output == 0 ? "none" : describe(output),
            "inputs": deviceIDs().filter(hasInput).map(describe).joined(separator: " | "),
        ]
    }

    private nonisolated static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private nonisolated static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioInputDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    private nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        guard read(id, selector, into: &value), let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private nonisolated static func read<Value>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        into value: inout Value
    ) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Value>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) == noErr
        }
    }

    private nonisolated static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
#endif
