//
//  PairingDeepLink.swift
//  PrintPartyKit
//
//  Parses the pairing payload shared by the QR code and the `printparty://`
//  deep link. One implementation so the QR scanner, the URL-scheme handler,
//  and the unit tests all agree on the format:
//
//      printparty://pair?url=<percent-encoded-url>&code=<8-char-code>
//
//  Lives in the shared package so it can be unit-tested without an app target.
//

import Foundation

public enum PairingDeepLink {

    public struct Payload: Equatable {
        public let url: String
        public let code: String

        public init(url: String, code: String) {
            self.url = url
            self.code = code
        }
    }

    /// Parse a `printparty://pair?...` string. Returns nil for any other
    /// scheme/host or when either parameter is missing.
    public static func parse(_ string: String) -> Payload? {
        guard let components = URLComponents(string: string) else { return nil }
        return parse(components)
    }

    /// Parse from a `URL` (used by SwiftUI's `.onOpenURL`).
    public static func parse(_ url: URL) -> Payload? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return parse(components)
    }

    private static func parse(_ components: URLComponents) -> Payload? {
        guard components.scheme?.lowercased() == "printparty",
              components.host?.lowercased() == "pair",
              let items = components.queryItems,
              let url = items.first(where: { $0.name == "url" })?.value, !url.isEmpty,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { return nil }
        // The gateway uppercases codes; normalize here so a lowercased scan works.
        return Payload(url: url, code: code.uppercased())
    }
}
