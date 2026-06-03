//
//  MQTTPacket.swift
//  PrintParty
//
//  Minimal MQTT 3.1.1 packet encoder/decoder.
//
//  Supports only the packet types and options PrintParty's Bambu LAN
//  integration actually needs:
//
//      CONNECT      (out)  with username + password, clean session
//      CONNACK      (in)   return code parsed
//      SUBSCRIBE    (out)  single topic, QoS 0
//      SUBACK       (in)   packet id only
//      PUBLISH      (in/out) QoS 0 only; no retained flag handling
//      PINGREQ      (out)
//      PINGRESP     (in)
//      DISCONNECT   (out)
//
//  This is *not* a general-purpose MQTT library. QoS 1/2, Will, retained
//  messages, sessions, and MQTT 5 properties are intentionally absent.
//

import Foundation

enum MQTTPacket {

    // MARK: - Outgoing

    /// CONNECT packet — protocol level 4 (MQTT 3.1.1), clean session.
    static func connect(
        clientId: String,
        username: String?,
        password: String?,
        keepAliveSeconds: UInt16
    ) -> Data {
        var variableHeader = Data()
        variableHeader.append(encodeString("MQTT"))
        variableHeader.append(0x04)              // protocol level
        var flags: UInt8 = 0x02                  // clean session
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

    /// SUBSCRIBE packet — single topic filter, QoS 0.
    static func subscribe(packetId: UInt16, topic: String) -> Data {
        var body = Data()
        body.append(UInt8(packetId >> 8))
        body.append(UInt8(packetId & 0xFF))
        body.append(encodeString(topic))
        body.append(0x00)                        // requested QoS
        return fixedHeader(type: 0x82, body: body)
    }

    /// PUBLISH packet — QoS 0, no retain, no dup.
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

    /// Attempts to decode one packet from the head of `buffer`.
    /// Returns `(decoded, bytesConsumed)` if a complete packet is present,
    /// or `nil` if more bytes are needed.
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
        precondition(bytes.count <= 0xFFFF, "MQTT strings are limited to 65535 bytes")
        var out = Data(capacity: 2 + bytes.count)
        out.append(UInt8(bytes.count >> 8))
        out.append(UInt8(bytes.count & 0xFF))
        out.append(contentsOf: bytes)
        return out
    }

    static func encodeVarInt(_ value: Int) -> Data {
        precondition(value >= 0 && value <= 268_435_455, "MQTT remaining length out of range")
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

    /// Decode a variable-byte integer from `buffer` starting at offset `start`.
    /// Returns the value and writes the number of bytes consumed into `bytesRead`.
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
