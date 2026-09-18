// Prints whether any process is capturing from each input device (the same CoreAudio
// property hs.audiodevice:inUse() reads), to see if Wispr only opens the mic while listening.
import CoreAudio
import Foundation

func propertyAddress(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

var devicesAddress = propertyAddress(kAudioHardwarePropertyDevices)
var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize)
var deviceIdentifiers = [AudioDeviceID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize, &deviceIdentifiers)

for deviceIdentifier in deviceIdentifiers {
    var streamsAddress = propertyAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var streamsSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(deviceIdentifier, &streamsAddress, 0, nil, &streamsSize)
    guard streamsSize > 0 else { continue }

    var nameAddress = propertyAddress(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(deviceIdentifier, &nameAddress, 0, nil, &nameSize, &name)

    var runningAddress = propertyAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var isRunning: UInt32 = 0
    var runningSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(deviceIdentifier, &runningAddress, 0, nil, &runningSize, &isRunning)
    print("\(name?.takeRetainedValue() as String? ?? "?"): inUse=\(isRunning != 0)")
}
