/*
 * media-sensor - report whether the camera or microphone is currently in use.
 *
 * Prints one line, e.g.:
 *     camera=1 mic=0
 *
 * Exit code is 0 on success regardless of what was detected.
 *
 * WHY SWIFT, AND WHY THESE APIS
 *
 * The properties below are the supported way to ask "is this device running
 * for anyone on the system":
 *
 *   microphone  kAudioDevicePropertyDeviceIsRunningSomewhere    (CoreAudio)
 *   camera      kCMIODevicePropertyDeviceIsRunningSomewhere     (CoreMediaIO)
 *
 * The popular alternatives are worse. Scraping `log stream` for camera events
 * depends on private subsystem names that change between macOS releases, and
 * checking for running processes named zoom/teams only tells you the app is
 * open, not that it is actually capturing.
 *
 * Reading these properties does NOT require camera or microphone permission,
 * because we never access any media - we only query device state. That means
 * no TCC prompt and no privacy entry for this binary.
 *
 * Build:
 *   swiftc -O media_sensor.swift -o ../bin/media-sensor
 */

import Foundation
import CoreAudio
import CoreMediaIO

// ---------------------------------------------------------------------------
// Microphone, via CoreAudio
// ---------------------------------------------------------------------------

func microphoneInUse() -> Bool {
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

    let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    guard deviceCount > 0 else { return false }

    var devices = [AudioObjectID](repeating: 0, count: deviceCount)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize, &devices
    ) == noErr else {
        return false
    }

    for device in devices {
        // Skip devices with no input streams - output-only devices report as
        // "running" whenever audio is playing, which would make every song
        // look like a meeting.
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

// ---------------------------------------------------------------------------
// Camera, via CoreMediaIO
// ---------------------------------------------------------------------------

func cameraInUse() -> Bool {
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

    let deviceCount = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
    guard deviceCount > 0 else { return false }

    var devices = [CMIOObjectID](repeating: 0, count: deviceCount)
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

// ---------------------------------------------------------------------------

let camera = cameraInUse()
let mic = microphoneInUse()

print("camera=\(camera ? 1 : 0) mic=\(mic ? 1 : 0)")
