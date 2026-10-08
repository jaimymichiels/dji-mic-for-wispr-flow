import Foundation
import IOKit
import IOUSBHost
import Darwin

// Only interface 6 and its IN endpoint are opened. Never capture/seize the device,
// reset it, detach a driver, or send settings commands. HID/audio stay with macOS.
private final class Receiver {
    let interface: IOUSBHostInterface
    let pipe: IOUSBHostPipe

    init?(service: io_service_t) throws {
        let interface = try IOUSBHostInterface(__ioService: service, options: [],
            queue: nil, interestHandler: nil)
        do {
            self.pipe = try interface.copyPipe(withAddress: 0x86)
            self.interface = interface
        } catch {
            interface.destroy()
            throw error
        }
    }

    deinit { interface.destroy() }

    func read() throws -> [UInt8] {
        let data = NSMutableData(length: 512)!
        var transferred = 0
        try pipe.__sendIORequest(with: data, bytesTransferred: &transferred, completionTimeout: 1)
        return Array((data as Data).prefix(transferred))
    }

    static func open() throws -> Receiver? {
        let matching: [String: Any] = [
            "IOProviderClass": "IOUSBHostInterface",
            "IOPropertyMatch": ["idVendor": 0x2CA3, "idProduct": 0x4011, "bInterfaceNumber": 6],
        ]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return try Receiver(service: service)
    }
}

@main
enum DJIBatteryReader {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.isEmpty || arguments == ["--watch"] else {
            FileHandle.standardError.write(Data("Usage: dji_battery [--watch]\n".utf8))
            exit(2)
        }
        let watch = arguments == ["--watch"]
        var lastStatus: BatteryStatus?
        var lastEmission = Date.distantPast
        func emit(_ status: BatteryStatus) {
            // Keep stdout bounded while emitting regular status updates to consumers.
            guard status != lastStatus || Date().timeIntervalSince(lastEmission) >= 1 else { return }
            if let data = try? JSONEncoder().encode(status) {
                FileHandle.standardOutput.write(data + Data([0x0A]))
            }
            lastStatus = status
            lastEmission = Date()
        }

        repeat {
            do {
                guard let receiver = try Receiver.open() else {
                    emit(BatteryStatus(state: "disconnected", transmitters: [],
                        message: "Connect the DJI receiver using USB-C."))
                    if !watch { return }
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
                var decoder = BatteryDecoder()
                var latest: BatteryStatus?
                var lastReading = Date()
                if watch {
                    emit(BatteryStatus(state: "waiting", transmitters: [],
                        message: "Waiting for transmitter battery status…"))
                }
                while true {
                    do {
                        let bytes = try receiver.read()
                        for status in decoder.feed(bytes) {
                            latest = status
                            lastReading = Date()
                            if !watch { emit(status); return }
                        }
                    } catch {
                        let error = error as NSError
                        // A bulk read timeout doesn't mean the receiver was unplugged.
                        guard [UInt32(0xE00002D6), 0xE0004051].contains(UInt32(truncatingIfNeeded: error.code))
                            else { throw error }
                    }
                    if Date().timeIntervalSince(lastReading) > 5 {
                        emit(BatteryStatus(state: "waiting", transmitters: [],
                            message: "No recent battery data. Check the receiver and transmitters."))
                        break // Release/reopen the interface after silence or wake.
                    }
                    if let status = latest { emit(status) }
                }
            } catch {
                emit(BatteryStatus(state: "error", transmitters: [],
                    message: "USB status unavailable: \(error.localizedDescription)"))
            }
            if watch { Thread.sleep(forTimeInterval: 2) }
        } while watch
    }
}
