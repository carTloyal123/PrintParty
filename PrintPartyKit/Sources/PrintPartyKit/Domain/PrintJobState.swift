//
//  PrintJobState.swift
//  PrintParty
//
//  The normalized snapshot every adapter produces and every UI consumes.
//  This is the wire format that will eventually be encrypted into the
//  Live Activity ContentState envelope. Keep it small and Codable.
//

import Foundation

public struct PrintJobState: Codable, Equatable, Sendable, Hashable {

    // MARK: Identity

    /// Stable identifier for the printer producing this state.
    public var printerId: UUID

    /// Human-readable printer name (e.g. "Garage A1 Mini").
    public var printerDisplayName: String

    /// Printer model string (e.g. "Bambu Lab A1 Mini").
    public var printerModel: String

    // MARK: Job

    /// Adapter-synthesized job identifier; nil when stage is .idle.
    public var jobId: UUID?

    /// Job/file name reported by the printer, e.g. "benchy.gcode".
    public var jobName: String?

    public var stage: PrinterStage

    /// Optional human-readable detail under the top-level `stage`. Set by
    /// vendor adapters when the printer reports a finer-grained activity —
    /// e.g. "Calibrating extrusion flow" while `stage` is `.preparing`, or
    /// "Inspecting first layer" while `stage` is `.printing`.
    ///
    /// Nil when there's no extra detail beyond what `stage` already conveys.
    public var substageMessage: String?

    /// 0.0 ... 100.0
    public var progressPercent: Double

    public var currentLayer: Int?
    public var totalLayers: Int?

    public var startedAt: Date?
    public var estimatedEndAt: Date?

    // MARK: Telemetry

    public var nozzleTempC: Double?
    public var nozzleTargetC: Double?
    public var bedTempC: Double?
    public var bedTargetC: Double?

    // MARK: Failure

    public var errorCode: String?
    public var errorMessage: String?

    // MARK: Bookkeeping

    public var updatedAt: Date

    public init(
        printerId: UUID,
        printerDisplayName: String,
        printerModel: String,
        jobId: UUID? = nil,
        jobName: String? = nil,
        stage: PrinterStage = .idle,
        substageMessage: String? = nil,
        progressPercent: Double = 0,
        currentLayer: Int? = nil,
        totalLayers: Int? = nil,
        startedAt: Date? = nil,
        estimatedEndAt: Date? = nil,
        nozzleTempC: Double? = nil,
        nozzleTargetC: Double? = nil,
        bedTempC: Double? = nil,
        bedTargetC: Double? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = .now
    ) {
        self.printerId = printerId
        self.printerDisplayName = printerDisplayName
        self.printerModel = printerModel
        self.jobId = jobId
        self.jobName = jobName
        self.stage = stage
        self.substageMessage = substageMessage
        self.progressPercent = progressPercent
        self.currentLayer = currentLayer
        self.totalLayers = totalLayers
        self.startedAt = startedAt
        self.estimatedEndAt = estimatedEndAt
        self.nozzleTempC = nozzleTempC
        self.nozzleTargetC = nozzleTargetC
        self.bedTempC = bedTempC
        self.bedTargetC = bedTargetC
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    /// Convenience: an idle snapshot for a newly-registered printer.
    public static func idle(
        printerId: UUID,
        displayName: String,
        model: String
    ) -> PrintJobState {
        PrintJobState(
            printerId: printerId,
            printerDisplayName: displayName,
            printerModel: model,
            stage: .idle
        )
    }
}
