import Foundation

@main
enum BatteryProtocolTests {
    static func bytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    // Captured from a real firmware-v2 receiver. No serial numbers or audio data.
    static let liveFrame = bytes("55 56 04 67 5a 02 00 00 00 5b 03 03 46 00 03 00 00 00 00 20 00 31 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01 00 00 00 1e 00 00 00 02 01 00 00 00 1a 98 24 04 01 00 78 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 75 5c")

    static func seal(_ body: [UInt8], seed: UInt16 = 0x3692) -> [UInt8] {
        let crc = BatteryDecoder.crc16(body, seed: seed)
        return body + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    static func status(slots: [(Int, Int, Bool)], mask: UInt8) -> [UInt8] {
        var body = Array(liveFrame.prefix(52))
        body[1] = UInt8(54 + slots.count * 32)
        body[3] = BatteryDecoder.headerCRC(Array(body.prefix(3)))
        body[12] = UInt8(0x26 + slots.count * 0x20)
        body[44] = mask
        for (unit, gauge, charging) in slots {
            var slot = Array(repeating: UInt8(0), count: 32)
            slot[0] = 2; slot[1] = UInt8(unit); slot[5] = 26
            slot[7] = 0x20 | UInt8(gauge << 2) | (charging ? 2 : 0)
            body += slot
        }
        return seal(body)
    }

    static func main() {
        assert(BatteryDecoder.headerCRC(bytes("55 56 04")) == 0x67)
        assert(BatteryDecoder.headerCRC(bytes("55 13 04")) == 0x03)
        assert(BatteryDecoder.crc16(liveFrame, seed: 0x3692) == 0)
        var decoder = BatteryDecoder()
        let full = BatteryStatus(state: "connected", transmitters: [
            TransmitterBattery(unit: 1, gauge: 1, charging: false),
        ])
        assert(decoder.feed(liveFrame) == [full])

        // A USB read can split the packet anywhere, or include several packets.
        for cut in 0...liveFrame.count {
            var fragmented = BatteryDecoder()
            let result = fragmented.feed(Array(liveFrame.prefix(cut)))
                + fragmented.feed(Array(liveFrame.dropFirst(cut)))
            assert(result == [full], "split at \(cut)")
        }
        assert(decoder.feed([0xFF, 0x55, 2, 0, 0xEE, 0x10] + liveFrame + liveFrame) == [full, full])
        var corrupt = liveFrame
        corrupt[59] ^= 0x10
        assert(decoder.feed(corrupt + liveFrame) == [full], "reject corrupt CRC and resync")

        // Physical unit IDs, rather than slot order, identify each transmitter.
        let two = decoder.feed(status(slots: [(2, 6, true), (1, 3, false)], mask: 3))[0]
        assert(two.transmitters == [TransmitterBattery(unit: 1, gauge: 3, charging: false),
            TransmitterBattery(unit: 2, gauge: 6, charging: true)])
        let loneTX2 = decoder.feed(status(slots: [(2, 7, false)], mask: 2))[0]
        assert(loneTX2.transmitters == [TransmitterBattery(unit: 2, gauge: 7, charging: false)])
        assert(decoder.feed(status(slots: [], mask: 0))[0].transmitters.isEmpty)
        assert(decoder.feed(status(slots: [], mask: 1))[0].transmitters[0].gauge == nil)
        assert(decoder.feed(status(slots: [(1, 0, false)], mask: 1))[0].transmitters[0].gauge == nil)
        assert(decoder.feed(status(slots: [(1, 1, false)], mask: 0))[0].transmitters.isEmpty)
        assert(decoder.feed(status(slots: [(1, 1, false), (1, 2, false)], mask: 1)).isEmpty)

        // A same-length identity packet must not be mistaken for battery status.
        var identity = Array(liveFrame.dropLast(2))
        identity[12] = 70; identity[52] = 1
        assert(decoder.feed(seal(identity)).isEmpty)

        let oldHeartbeat = bytes("55 38 04 e1 5a 02 00 00 00 5b 03 00")
            + Array(repeating: UInt8(0), count: 42)
        // For v1, append the CRC that produces the known 0xBB01 residue.
        let oldFrame = oldHeartbeat + (0...65535).lazy.compactMap { value -> [UInt8]? in
            let suffix = [UInt8(value & 255), UInt8(value >> 8)]
            return BatteryDecoder.crc16(oldHeartbeat + suffix, seed: 0) == 0xBB01 ? suffix : nil
        }.first!
        assert(decoder.feed(oldFrame)[0].state == "unsupported")
        print("Battery protocol checks passed (live fixture, 87 split points, CRC recovery, TX IDs, charging, unknown and disconnected states).")
    }
}
