//
//  MQTTPacket.swift
//  printparty-gateway
//
//  Identical to the iOS MQTTPacket.swift — minimal MQTT 3.1.1 codec.
//  Copied here because the gateway runs on Linux and can't import
//  Network.framework. When PrintPartyKit becomes a shared SPM package
//  this duplication goes away.
//

import Foundation

enum MQTTPacket {

    // MARK: - Outgoing

    static func connect(
        clientId: String,
        username: String?,
        password: String?,
        keepAliveSeconds: UInt16
    ) -> Data {
        var variableHeader = Data()
        variableHeader.append(encodeString("MQTT"))
        variableHeader.append(0x04)
        var flags: UInt8 = 0x02
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        variableHeader.append(flags)
        variableHeader.append(UInt8(keepAliveSeconds >> 8))
        variableHeader.append(UInt8(keepAliveSeconds & 0xFF))

        var payload = Data()
        payload.append(encodeString(clientId))
        if let u = username { payload.append(encodeString(u)) }
        if let p = password { payload.append(encodeString(p)) }

        return fixedHeader(type: 0x10, body: variableHeader + payload)
    }

    static func subscribe(packetId: UInt16, topic: String) -> Data {
        var body = Data()
        body.append(UInt8(packetId >> 8))
        body.append(UInt8(packetId & 0xFF))
        body.append(encodeString(topic))
        body.append(0x00)
        return fixedHeader(type: 0x82, body: body)
    }

    static func publish(topic: String, payload: Data) -> Data {
        var body = Data()
        body.append(encodeString(topic))
        body.append(payload)
        return fixedHeader(type: 0x30, body: body)
    }

    static let pingreq    = Data([0xC0, 0x00])
    static let disconnect = Data([0xE0, 0x00])

    // MARK: - Incoming

    enum Decoded {
        case connack(returnCode: UInt8)
        case suback(packetId: UInt16)
        case publish(topic: String, payload: Data)
        case pingresp
        case unknown(type: UInt8)
    }

    static func tryDecode(_ buffer: Data) -> (packet: Decoded, bytesConsumed: Int)? {
        guard let firstByte = buffer.first else { return nil }
        let type  = (firstByte >> 4) & 0x0F
        let flags = firstByte & 0x0F

        var remainingLengthBytes = 0
        guard let remainingLength = decodeVarInt(buffer, startingAt: 1, bytesRead: &remainingLengthBytes) else {
            return nil
        }
        let headerLength = 1 + remainingLengthBytes
        let totalLength = headerLength + remainingLength
        guard buffer.count >= totalLength else { return nil }

        let bodyStart = buffer.startIndex + headerLength
        let bodyEnd   = bodyStart + remainingLength
        let body = buffer[bodyStart..<bodyEnd]

        let decoded: Decoded
        switch type {
        case 0x02:
            guard body.count >= 2 else { return nil }
            decoded = .connack(returnCode: body[body.startIndex + 1])
        case 0x03:
            var offset = body.startIndex
            guard let topic = readString(body, offset: &offset, end: body.endIndex) else { return nil }
            let qos = (flags >> 1) & 0x03
            if qos > 0 {
                guard body.distance(from: offset, to: body.endIndex) >= 2 else { return nil }
                offset = body.index(offset, offsetBy: 2)
            }
            let payload = Data(body[offset..<body.endIndex])
            decoded = .publish(topic: topic, payload: payload)
        case 0x09:
            guard body.count >= 2 else { return nil }
            let pid = (UInt16(body[body.startIndex]) << 8) | UInt16(body[body.startIndex + 1])
            decoded = .suback(packetId: pid)
        case 0x0D:
            decoded = .pingresp
        default:
            decoded = .unknown(type: type)
        }
        return (decoded, totalLength)
    }

    // MARK: - Helpers

    private static func fixedHeader(type firstByte: UInt8, body: Data) -> Data {
        var data = Data()
        data.append(firstByte)
        data.append(encodeVarInt(body.count))
        data.append(body)
        return data
    }

    static func encodeString(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var out = Data(capacity: 2 + bytes.count)
        out.append(UInt8(bytes.count >> 8))
        out.append(UInt8(bytes.count & 0xFF))
        out.append(contentsOf: bytes)
        return out
    }

    static func encodeVarInt(_ value: Int) -> Data {
        var out = Data()
        var x = value
        repeat {
            var byte = UInt8(x & 0x7F)
            x >>= 7
            if x > 0 { byte |= 0x80 }
            out.append(byte)
        } while x > 0
        return out
    }

    static func decodeVarInt(_ buffer: Data, startingAt start: Int, bytesRead: inout Int) -> Int? {
        var value = 0
        var multiplier = 1
        var n = 0
        while true {
            let idx = buffer.startIndex + start + n
            guard idx < buffer.endIndex else { return nil }
            let byte = buffer[idx]
            value += Int(byte & 0x7F) * multiplier
            n += 1
            if (byte & 0x80) == 0 { break }
            multiplier *= 128
            if n > 4 { return nil }
        }
        bytesRead = n
        return value
    }

    private static func readString(_ data: Data, offset: inout Data.Index, end: Data.Index) -> String? {
        guard data.distance(from: offset, to: end) >= 2 else { return nil }
        let hi = Int(data[offset])
        let lo = Int(data[data.index(after: offset)])
        let len = (hi << 8) | lo
        let stringStart = data.index(offset, offsetBy: 2)
        guard data.distance(from: stringStart, to: end) >= len else { return nil }
        let stringEnd = data.index(stringStart, offsetBy: len)
        let s = String(data: data[stringStart..<stringEnd], encoding: .utf8)
        offset = stringEnd
        return s
    }
}
