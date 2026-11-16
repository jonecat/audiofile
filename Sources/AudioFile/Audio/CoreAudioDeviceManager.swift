import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let deviceID: AudioDeviceID
    public let name: String
    public let nominalSampleRate: Double
    public let supportedSampleRates: [Double]
    public let isSystemDefault: Bool

    public var formattedSampleRate: String {
        if nominalSampleRate >= 1000 {
            let khz = nominalSampleRate / 1000.0
            if khz == khz.rounded() {
                return String(format: "%.0f kHz", khz)
            }
            return String(format: "%.1f kHz", khz)
        }
        return "\(Int(nominalSampleRate)) Hz"
    }
}

public enum CoreAudioDeviceManager {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    public static func outputDevices() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        var result: [AudioOutputDevice] = []
        if let defID = defaultOutputDeviceID() {
            let defName = deviceName(for: defID) ?? "System Default"
            let defRate = nominalSampleRate(for: defID) ?? 44_100
            let defRates = supportedSampleRates(for: defID)
            result.append(AudioOutputDevice(
                id: "system_default",
                deviceID: defID,
                name: "System Default (\(defName))",
                nominalSampleRate: defRate,
                supportedSampleRates: defRates,
                isSystemDefault: true
            ))
        }

        for id in deviceIDs {
            guard hasOutputStreams(deviceID: id),
                  let uid = deviceUID(for: id),
                  let name = deviceName(for: id) else {
                continue
            }
            let rate = nominalSampleRate(for: id) ?? 44_100
            let rates = supportedSampleRates(for: id)
            result.append(AudioOutputDevice(
                id: uid,
                deviceID: id,
                name: name,
                nominalSampleRate: rate,
                supportedSampleRates: rates,
                isSystemDefault: false
            ))
        }

        return result
    }

    public static func resolveDevice(uid: String?) -> AudioOutputDevice? {
        let devices = outputDevices()
        if let uid = uid, uid != "system_default",
           let match = devices.first(where: { $0.id == uid && !$0.isSystemDefault }) {
            return match
        }
        return devices.first(where: { $0.isSystemDefault }) ?? devices.first
    }

    @discardableResult
    public static func setOutputDevice(uid: String?, on playerEngine: AVAudioEngine) -> AudioOutputDevice? {
        let resolved = resolveDevice(uid: uid)
        guard let target = resolved,
              let audioUnit = playerEngine.outputNode.audioUnit else {
            return resolved
        }

        var devID = target.deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("CoreAudioDeviceManager: failed to set output device \(target.name) (OSStatus \(status))")
        }
        return target
    }

    @discardableResult
    public static func switchSampleRateIfSupported(_ targetRate: Double, on deviceID: AudioDeviceID) -> Double {
        let current = nominalSampleRate(for: deviceID) ?? 44_100
        guard targetRate > 0 else { return current }

        let ranges = availableSampleRateRanges(for: deviceID)
        guard !ranges.isEmpty else { return current }

        var chosenRate: Double?
        for range in ranges {
            if targetRate >= range.mMinimum - 0.5 && targetRate <= range.mMaximum + 0.5 {
                chosenRate = targetRate
                break
            }
        }

        if chosenRate == nil {
            var candidates: [Double] = []
            for range in ranges {
                for std in standardSampleRates where std >= range.mMinimum - 0.5 && std <= range.mMaximum + 0.5 {
                    candidates.append(std)
                }
                candidates.append(range.mMinimum)
                candidates.append(range.mMaximum)
            }
            // Prefer exact integer multiples (e.g. 88.2kHz for 44.1kHz, 96kHz for 48kHz) when exact rate isn't supported
            chosenRate = candidates.min(by: { a, b in
                let aMultiple = (Int(a.rounded()) % Int(targetRate.rounded()) == 0) || (Int(targetRate.rounded()) % Int(a.rounded()) == 0)
                let bMultiple = (Int(b.rounded()) % Int(targetRate.rounded()) == 0) || (Int(targetRate.rounded()) % Int(b.rounded()) == 0)
                if aMultiple != bMultiple {
                    return aMultiple
                }
                return abs(a - targetRate) < abs(b - targetRate)
            })
        }

        guard let bestRate = chosenRate else { return current }
        if abs(bestRate - current) < 1.0 {
            return current
        }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var newRate = Float64(bestRate)
        let status = AudioObjectSetPropertyData(
            deviceID,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &newRate
        )
        if status == noErr {
            return bestRate
        }
        return current
    }

    @discardableResult
    public static func setHogMode(enabled: Bool, on deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }

        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &addr, &isSettable) == noErr, isSettable.boolValue else {
            return false
        }

        var pid: pid_t = enabled ? getpid() : -1
        let status = AudioObjectSetPropertyData(
            deviceID,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<pid_t>.size),
            &pid
        )
        if status != noErr {
            return false
        }

        var currentPid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &currentPid) == noErr {
            return enabled ? (currentPid == getpid()) : (currentPid != getpid())
        }
        return enabled
    }

    public static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate)
        return (status == noErr && rate > 0) ? Double(rate) : nil
    }

    private static func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let retained = cfStr?.takeRetainedValue() else { return nil }
        return retained as String
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let retained = cfStr?.takeRetainedValue() else { return nil }
        return retained as String
    }

    private static func availableSampleRateRanges(for deviceID: AudioDeviceID) -> [AudioValueRange] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &ranges) == noErr else {
            return []
        }
        return ranges
    }

    private static func supportedSampleRates(for deviceID: AudioDeviceID) -> [Double] {
        let ranges = availableSampleRateRanges(for: deviceID)
        var set = Set<Double>()
        for range in ranges {
            if abs(range.mMinimum - range.mMaximum) < 1.0, range.mMinimum > 0 {
                set.insert(range.mMinimum)
            } else {
                for std in standardSampleRates where std >= range.mMinimum - 0.5 && std <= range.mMaximum + 0.5 {
                    set.insert(std)
                }
            }
        }
        return set.sorted()
    }
}
