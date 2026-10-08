import Foundation

// Read-only subset of the reverse-engineered DJI Mic Mini v2 USB protocol:
// https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md
struct TransmitterBattery: Codable, Equatable {
    let unit: Int
    let gauge: Int?
    let charging: Bool?
}

struct BatteryStatus: Codable, Equatable {
    let state: String
    let transmitters: [TransmitterBattery]
    var message: String? = nil
}

struct BatteryDecoder {
    private var buffer: [UInt8] = []

    static func crc16(_ bytes: [UInt8], seed: UInt16) -> UInt16 {
        bytes.reduce(seed) { crc, byte in
            var value = crc ^ UInt16(byte)
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0x8408 }
            return value
        }
    }

    static func headerCRC(_ bytes: [UInt8]) -> UInt8 {
        // Live receiver frames use the DUML seed 0x77 (the upstream prose
        // lists 0xEE, which doesn't reproduce its own example headers).
        bytes.reduce(UInt8(0x77)) { crc, byte in
            var value = crc ^ byte
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0x8C }
            return value
        }
    }

    mutating func feed(_ bytes: [UInt8]) -> [BatteryStatus] {
        buffer.append(contentsOf: bytes)
        var statuses: [BatteryStatus] = []
        while buffer.count >= 4 {
            let length = Int(buffer[1])
            guard buffer[0] == 0x55, buffer[2] == 0x04, length >= 14,
                  Self.headerCRC(Array(buffer.prefix(3))) == buffer[3] else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= length else { break }
            let frame = Array(buffer.prefix(length))
            let version = frame[11]
            let valid = version == 3
                ? Self.crc16(frame, seed: 0x3692) == 0
                : Self.crc16(frame, seed: 0) == 0xBB01
            guard valid else {
                buffer.removeFirst()
                continue
            }
            buffer.removeFirst(length)
            guard frame[8] == 0, frame[9] == 0x5B, frame[10] == 3 else { continue }
            if version == 0 {
                statuses.append(BatteryStatus(state: "unsupported", transmitters: [],
                    message: "Battery readings require DJI firmware version 2."))
                continue
            }
            guard version == 3, [54, 86, 118].contains(length) else { continue }
            let count = (length - 54) / 32
            guard frame[12] == UInt8(0x26 + count * 0x20) else { continue }
            var slots: [Int: TransmitterBattery] = [:]
            var validSlots = true
            for index in 0..<count {
                let offset = 52 + index * 32
                let unit = Int(frame[offset + 1])
                guard frame[offset] == 2, (1...2).contains(unit),
                      slots[unit] == nil, frame[offset + 5] == 26 else {
                    validSlots = false
                    break
                }
                let flags = frame[offset + 7]
                let gauge = Int((flags >> 2) & 7)
                slots[unit] = TransmitterBattery(unit: unit, gauge: gauge == 0 ? nil : gauge,
                    charging: flags & 2 != 0)
            }
            guard validSlots else { continue }
            // The connected bitmask can precede the slot by one status tick.
            let transmitters = (1...2).compactMap { unit -> TransmitterBattery? in
                guard frame[44] & UInt8(1 << (unit - 1)) != 0 else { return nil }
                return slots[unit] ?? TransmitterBattery(unit: unit, gauge: nil, charging: nil)
            }
            statuses.append(BatteryStatus(state: "connected", transmitters: transmitters))
        }
        return statuses
    }
}
