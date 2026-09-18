// Registers F18 as a Carbon global hotkey, the same API hs.hotkey uses, and prints each
// press. Carbon hotkeys need no Accessibility or Input Monitoring grant, so this tests the
// native route exactly as Hammerspoon will see it.
import AppKit
import Carbon.HIToolbox

setvbuf(stdout, nil, _IOLBF, 0)
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

let timestampFormatter = DateFormatter()
timestampFormatter.dateFormat = "HH:mm:ss.SSS"

var pressedEventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
    print("\(timestampFormatter.string(from: Date())) F18 hotkey fired")
    return noErr
}, 1, &pressedEventType, nil, nil)

var hotKeyReference: EventHotKeyRef?
let hotKeyIdentifier = EventHotKeyID(signature: OSType(0x444A4931), id: 1)
// Exclusive registration fails with -9878 if another app already owns F18.
let registerStatus = RegisterEventHotKey(UInt32(kVK_F18), 0, hotKeyIdentifier, GetEventDispatcherTarget(),
                                         OptionBits(kEventHotKeyExclusive), &hotKeyReference)
print("\(timestampFormatter.string(from: Date())) InstallEventHandler=\(handlerStatus) RegisterEventHotKey(F18)=\(registerStatus)")
guard handlerStatus == noErr, registerStatus == noErr else {
    if registerStatus == OSStatus(eventHotKeyExistsErr) {
        print("F18 is already registered by another app; quit Hammerspoon if dji_wispr is running")
    }
    exit(1)
}

let durationSeconds = Double(CommandLine.arguments.dropFirst().first ?? "150") ?? 150
DispatchQueue.main.asyncAfter(deadline: .now() + durationSeconds) { exit(0) }
application.run()
