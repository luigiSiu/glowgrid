import Foundation
import CoreAudio
import CoreMediaIO

/*
 * Reports whether the camera or microphone is currently in use.
 *
 * Ported from mac-cli/media-sensor/media_sensor.swift, which stays around as a
 * standalone binary for the Python watcher. The logic is identical; only the
 * packaging differs.
 *
 * These are the supported "is this device running for anybody" properties:
 *
 *   microphone  kAudioDevicePropertyDeviceIsRunningSomewhere    (CoreAudio)
 *   camera      kCMIODevicePropertyDeviceIsRunningSomewhere     (CoreMediaIO)
 *
 * Rejected alternatives: scraping `log stream` depends on private subsystem
 * names that change between macOS releases, and matching process names only
 * proves an app is open, not that it is capturing.
 *
 * Reading these requires NO camera or microphone permission, because no media
 * is ever accessed - only device state is queried. So this triggers no TCC
 * prompt, which is why the app asks for Bluetooth access and nothing else.
 */
enum MediaSensor {

    static func microphoneInUse() -> Bool {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize
        ) == noErr else {
            return false
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return false }

        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize, &devices
        ) == noErr else {
            return false
        }

        for device in devices {
            /*
             * Skip devices with no input streams. Output-only devices report
             * as "running" whenever any audio is playing, so without this
             * check every song would look like a meeting.
             */
            var inputStreams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &inputStreams, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else {
                continue
            }

            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)

            if AudioObjectGetPropertyData(
                device, &runningAddress, 0, nil, &runningSize, &running
            ) == noErr, running != 0 {
                return true
            }
        }

        return false
    }

    static func cameraInUse() -> Bool {
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, 0, nil, &dataSize
        ) == noErr else {
            return false
        }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return false }

        var devices = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, 0, nil,
            dataSize, &dataUsed, &devices
        ) == noErr else {
            return false
        }

        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var running: UInt32 = 0
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<UInt32>.size)

            if CMIOObjectGetPropertyData(
                device, &runningAddress, 0, nil, size, &used, &running
            ) == noErr, running != 0 {
                return true
            }
        }

        return false
    }
}
