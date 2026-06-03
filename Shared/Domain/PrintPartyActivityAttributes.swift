//
//  PrintPartyActivityAttributes.swift
//  PrintParty (shared between app and widget extension)
//
//  ActivityKit contract for a single tracked print job.
//
//  In a future phase the `ContentState` will become an encrypted envelope
//  `{ printerId, v, nonce, ciphertext }` that the widget decrypts using a key
//  shared with the user's gateway (per the v2 architecture plan). For now we
//  send the normalized `PrintJobState` directly so the UI can be built and
//  tested end-to-end.
//

import Foundation
import ActivityKit

public struct PrintPartyActivityAttributes: ActivityAttributes {

    /// Live, frequently-updated job state. APNs payload limit (~4 KB) applies
    /// to this struct once we move to server-pushed updates, so keep it lean.
    public typealias ContentState = PrintJobState

    // MARK: Static identity (never changes for the lifetime of an activity)

    public let printerId: UUID
    public let printerDisplayName: String
    public let printerModel: String

    public init(
        printerId: UUID,
        printerDisplayName: String,
        printerModel: String
    ) {
        self.printerId = printerId
        self.printerDisplayName = printerDisplayName
        self.printerModel = printerModel
    }
}
