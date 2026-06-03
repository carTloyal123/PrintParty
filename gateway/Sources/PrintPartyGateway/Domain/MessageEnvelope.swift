//
//  MessageEnvelope.swift
//  printparty-gateway
//
//  Unified message format for WebSocket communication. Used both on LAN
//  (plaintext JSON) and via relay (encrypted). The `payload` field is a
//  base64-encoded JSON string so it can be generically encoded/decoded
//  without type erasure.
//

import Foundation

public enum MessageType: String, Codable, Sendable {
    case event, request, response, error
}

public struct MessageEnvelope: Codable, Sendable {
    public let type: MessageType
    public let id: String?
    public let method: String
    public let deviceId: String?
    /// Base64-encoded JSON of the method-specific data.
    public let payload: String

    public init(type: MessageType, id: String?, method: String, deviceId: String?, payload: String) {
        self.type = type
        self.id = id
        self.method = method
        self.deviceId = deviceId
        self.payload = payload
    }

    // MARK: - Factory helpers

    /// Create an event envelope (broadcast, no id).
    public static func event(method: String, payload: Data) -> MessageEnvelope {
        MessageEnvelope(
            type: .event,
            id: nil,
            method: method,
            deviceId: nil,
            payload: payload.base64EncodedString()
        )
    }

    /// Create a request envelope with a unique id.
    public static func request(id: String, method: String, deviceId: String?, payload: Data) -> MessageEnvelope {
        MessageEnvelope(
            type: .request,
            id: id,
            method: method,
            deviceId: deviceId,
            payload: payload.base64EncodedString()
        )
    }

    /// Create a response envelope echoing the request id.
    public static func response(id: String, method: String, payload: Data) -> MessageEnvelope {
        MessageEnvelope(
            type: .response,
            id: id,
            method: method,
            deviceId: nil,
            payload: payload.base64EncodedString()
        )
    }

    /// Create an error envelope with a code and human-readable message.
    public static func error(id: String, method: String, code: String, message: String) -> MessageEnvelope {
        struct ErrorPayload: Encodable {
            let code: String
            let message: String
        }
        let data = (try? JSONEncoder().encode(ErrorPayload(code: code, message: message))) ?? Data()
        return MessageEnvelope(
            type: .error,
            id: id,
            method: method,
            deviceId: nil,
            payload: data.base64EncodedString()
        )
    }

    // MARK: - Payload helpers

    /// Decode the base64 payload into raw Data.
    public func payloadData() -> Data? {
        Data(base64Encoded: payload)
    }

    /// Decode the base64 payload into a specific Decodable type.
    public func decodePayload<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
