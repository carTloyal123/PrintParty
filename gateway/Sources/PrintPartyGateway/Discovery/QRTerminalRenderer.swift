//
//  QRTerminalRenderer.swift
//  printparty-gateway
//
//  Builds the pairing deep-link payload and renders it as a scannable QR code
//  using Unicode half-block characters so it has the correct 1:1 aspect ratio
//  in a terminal (two QR rows per text line).
//

import QRCodeGenerator

enum QRTerminalRenderer {

    /// Build the QR/deep-link payload: `printparty://pair?url=<enc>&code=<code>`.
    static func pairingURL(baseURL: String, code: String) -> String {
        let encodedURL = baseURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? baseURL
        return "printparty://pair?url=\(encodedURL)&code=\(code)"
    }

    /// Render a QR code as a terminal string using Unicode half-block characters.
    /// Each text line encodes two QR rows: ▀ (top), ▄ (bottom), █ (both), space (neither).
    static func renderToTerminal(payload: String) -> String {
        guard let qr = try? QRCode.encode(text: payload, ecl: .medium) else {
            return "[QR encode failed]\n\(payload)"
        }
        let size = qr.size
        let quietZone = 2
        var lines: [String] = []

        for y in stride(from: -quietZone, to: size + quietZone, by: 2) {
            var line = ""
            for x in -quietZone..<(size + quietZone) {
                let top = isBlack(qr, x: x, y: y, size: size)
                let bottom = isBlack(qr, x: x, y: y + 1, size: size)
                switch (top, bottom) {
                case (true, true):   line += "\u{2588}"  // █
                case (true, false):  line += "\u{2580}"  // ▀
                case (false, true):  line += "\u{2584}"  // ▄
                case (false, false): line += " "
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A module outside the QR grid (quiet zone) is treated as white.
    private static func isBlack(_ qr: QRCode, x: Int, y: Int, size: Int) -> Bool {
        guard x >= 0, x < size, y >= 0, y < size else { return false }
        return qr.getModule(x: x, y: y)
    }
}
