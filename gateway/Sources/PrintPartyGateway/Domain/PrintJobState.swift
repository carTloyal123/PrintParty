//
//  PrintJobState.swift
//  printparty-gateway
//
//  Mirror of the iOS Shared/Domain/PrintJobState.swift. Kept as a copy
//  rather than a shared Swift package for now — the gateway runs on Linux
//  and doesn't import SwiftUI/ActivityKit, so a local copy is simpler.
//  When we add a shared SPM package (PrintPartyKit), this moves there.
//

import Foundation

public struct PrintJobState: Codable, Equatable, Sendable, Hashable {
    public var printerId: UUID
    public var printerDisplayName: String
    public var printerModel: String
    public var jobId: UUID?
    public var jobName: String?
    public var stage: PrinterStage
    public var substageMessage: String?
    public var progressPercent: Double
    public var currentLayer: Int?
    public var totalLayers: Int?
    public var startedAt: Date?
    public var estimatedEndAt: Date?
    public var nozzleTempC: Double?
    public var nozzleTargetC: Double?
    public var bedTempC: Double?
    public var bedTargetC: Double?
    public var errorCode: String?
    public var errorMessage: String?
    public var updatedAt: Date

    public init(
        printerId: UUID,
        printerDisplayName: String,
        printerModel: String,
        stage: PrinterStage = .idle,
        updatedAt: Date = Date()
    ) {
        self.printerId = printerId
        self.printerDisplayName = printerDisplayName
        self.printerModel = printerModel
        self.stage = stage
        self.progressPercent = 0
        self.updatedAt = updatedAt
    }

    public static func idle(printerId: UUID, displayName: String, model: String) -> PrintJobState {
        PrintJobState(printerId: printerId, printerDisplayName: displayName, printerModel: model, stage: .idle)
    }
}

public enum PrinterStage: String, Codable, Sendable, CaseIterable, Hashable {
    case idle, preparing, printing, paused, finishing, done, failed, canceled, offline

    public var isActive: Bool {
        switch self {
        case .preparing, .printing, .paused, .finishing: return true
        default: return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .canceled: return true
        default: return false
        }
    }
}
