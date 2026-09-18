// Listen-only event tap that prints, for every key / media-key event, which HID
// service sent it. Uses the private CGEventCopyIOHIDEvent + IOHIDEventGetSenderID
// pair because no public CGEvent field carries device identity for key events.
import AppKit
import IOKit

typealias CopyIOHIDEventFunction = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
typealias GetSenderIDFunction = @convention(c) (CFTypeRef) -> UInt64

func loadSymbol<T>(_ library: String, _ name: String, as _: T.Type) -> T {
    guard let handle = dlopen(library, RTLD_NOW), let symbol = dlsym(handle, name) else {
        FileHandle.standardError.write("missing symbol \(name) in \(library)\n".data(using: .utf8)!)
        exit(3)
    }
    return unsafeBitCast(symbol, to: T.self)
}

let copyIOHIDEvent = loadSymbol("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGEventCopyIOHIDEvent", as: CopyIOHIDEventFunction.self)
let getSenderID = loadSymbol("/System/Library/Frameworks/IOKit.framework/IOKit", "IOHIDEventGetSenderID", as: GetSenderIDFunction.self)

let mediaKeyNames: [Int: String] = [0: "SOUND_UP", 1: "SOUND_DOWN", 7: "MUTE", 16: "PLAY", 17: "NEXT", 18: "PREVIOUS", 19: "FAST", 20: "REWIND"]

func describeSender(_ senderID: UInt64) -> String {
    guard senderID != 0 else { return "sender=0 (unattributed)" }
    guard let service = Optional(IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(senderID))), service != 0 else {
        return String(format: "sender=0x%llx (no registry entry)", senderID)
    }
    defer { IOObjectRelease(service) }
    func property(_ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
    let vendorID = (property("VendorID") as? Int).map { String(format: "0x%04x", $0) } ?? "?"
    let productID = (property("ProductID") as? Int).map { String(format: "0x%04x", $0) } ?? "?"
    let product = property("Product") as? String ?? "?"
    return String(format: "sender=0x%llx vid=%@ pid=%@ product=\"%@\"", senderID, vendorID, productID, product)
}

let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    let description: String
    switch type.rawValue {
    case CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue:
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        description = "\(type == .keyDown ? "keyDown" : "keyUp  ") keycode=\(keycode)\(keycode == 79 ? " (F18)" : "")"
    case 14:
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let mediaKeyCode = (nsEvent.data1 & 0xFFFF0000) >> 16
        let isDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0xA
        description = "media   \(mediaKeyNames[mediaKeyCode] ?? "code=\(mediaKeyCode)") \(isDown ? "down" : "up")"
    default:
        return Unmanaged.passUnretained(event)
    }
    let senderDescription = copyIOHIDEvent(event).map { describeSender(getSenderID($0.takeRetainedValue())) } ?? "no IOHIDEvent attached"
    print("\(description.padding(toLength: 30, withPad: " ", startingAt: 0)) \(senderDescription)")
    fflush(stdout)
    return Unmanaged.passUnretained(event)
}

let arguments = CommandLine.arguments
if arguments.contains("--check") {
    print("input monitoring preflight: \(CGPreflightListenEventAccess())")
    exit(0)
}
if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }

let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << 14)
guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: eventMask, callback: eventTapCallback, userInfo: nil) else {
    print("event tap creation failed: grant Input Monitoring to your terminal app, then rerun")
    exit(2)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
let seconds = Double(arguments.dropFirst().first ?? "15") ?? 15
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
CFRunLoopRun()
