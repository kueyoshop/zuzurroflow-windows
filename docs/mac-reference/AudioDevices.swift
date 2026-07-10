import CoreAudio
import Foundation

/// Utilidades CoreAudio: localizar el micrófono INTEGRADO del MacBook y
/// fijarlo como entrada del AVAudioEngine, aunque haya AirPods conectados
/// (su micrófono es de baja calidad para dictado — comprimido y lejano).
enum AudioDevices {

    /// AudioDeviceID del micrófono integrado (transporte Built-In con entrada).
    static func builtInInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids where hasInput(id) && transportType(id) == kAudioDeviceTransportTypeBuiltIn {
            return id
        }
        return nil
    }

    static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr) == noErr else { return false }
        let list = ptr.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return transport
    }

    static func name(of id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &nameRef) == noErr,
              let cf = nameRef?.takeRetainedValue() else { return "¿?" }
        return cf as String
    }

    /// UID persistente del dispositivo (para guardar la elección del usuario).
    static func uid(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uidRef) == noErr,
              let cf = uidRef?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Todos los dispositivos de ENTRADA disponibles.
    static func allInputDevices() -> [(id: AudioDeviceID, name: String, uid: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = uid(of: id) else { return nil }
            return (id, name(of: id), uid)
        }
    }

    /// AudioDeviceID de la entrada POR DEFECTO del sistema.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// ¿Es un dispositivo Bluetooth (AirPods, cascos BT)? Sus micrófonos
    /// tardan ~2s en entregar audio real tras arrancar el motor (enlace HFP).
    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let t = transportType(id)
        return t == kAudioDeviceTransportTypeBluetooth
            || t == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Nombre del dispositivo de entrada POR DEFECTO del sistema.
    static func defaultInputName() -> String {
        guard let id = defaultInputDeviceID() else { return "¿?" }
        return name(of: id)
    }
}
