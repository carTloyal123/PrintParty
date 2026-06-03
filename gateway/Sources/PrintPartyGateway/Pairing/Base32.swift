//
//  Base32.swift
//  printparty-gateway
//
//  Minimal RFC 4648 Base32 encoder used for the 8-character pairing code.
//  Decoding is not needed (pairing codes only travel one way: gateway → user).
//

enum Base32 {

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ bytes: [UInt8]) -> String {
        var result = ""
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = (buffer >> bits) & 0x1F
                result.append(alphabet[index])
            }
        }
        if bits > 0 {
            let index = (buffer << (5 - bits)) & 0x1F
            result.append(alphabet[index])
        }
        return result
    }
}
