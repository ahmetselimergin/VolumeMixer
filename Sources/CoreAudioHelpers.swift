import AppKit
import AudioToolbox
import CoreAudio

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String
    var description: String { "\(operation) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw CoreAudioError(status: status, operation: operation) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                  default fallback: T) -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value)
        return status == noErr ? value : fallback
    }

    func write<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                   _ value: T) {
        var addr = address(selector, scope)
        var v = value
        AudioObjectSetPropertyData(self, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    func isSettable(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(self, &addr),
              AudioObjectIsPropertySettable(self, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    func readObjectList(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static var defaultOutputDevice: AudioObjectID {
        system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }
}

/// A process known to Core Audio (anything that has opened an audio connection).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let isRunningOutput: Bool

    static func all() -> [AudioProcess] {
        AudioObjectID.system.readObjectList(kAudioHardwarePropertyProcessObjectList).map { id in
            AudioProcess(
                objectID: id,
                pid: id.read(kAudioProcessPropertyPID, default: pid_t(-1)),
                isRunningOutput: id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            )
        }
    }
}

// Browsers play audio from helper processes (Chrome Helper, WebKit GPU process...).
// The kernel tracks which app is "responsible" for each helper; use that to group them.
private typealias ResponsiblePIDFn = @convention(c) (pid_t) -> pid_t
private let responsiblePID: ResponsiblePIDFn? = {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsiblePIDFn.self)
}()

func owningApplication(of pid: pid_t) -> NSRunningApplication? {
    var candidates = [pid]
    if let responsible = responsiblePID?(pid), responsible > 0, responsible != pid {
        candidates.insert(responsible, at: 0)
    }
    for candidate in candidates {
        if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy == .regular {
            return app
        }
    }
    // Fall back to the enclosing .app bundle of the helper's executable.
    if let url = NSRunningApplication(processIdentifier: pid)?.executableURL {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if dir.pathExtension == "app",
               let bundleID = Bundle(url: dir)?.bundleIdentifier,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                   .first(where: { $0.activationPolicy == .regular }) {
                return app
            }
            dir = dir.deletingLastPathComponent()
        }
    }
    return nil
}

/// The output device's own volume (what the keyboard volume keys change).
struct SystemOutput {
    let device: AudioObjectID

    var name: String { device.readString(kAudioObjectPropertyName) ?? "Output device" }

    var hasVolume: Bool {
        device.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    }

    var volume: Float {
        get { device.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, default: Float32(1)) }
        nonmutating set { device.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, Float32(newValue)) }
    }

    var isMuted: Bool {
        get { device.read(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, default: UInt32(0)) != 0 }
        nonmutating set { device.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(newValue ? 1 : 0)) }
    }
}
