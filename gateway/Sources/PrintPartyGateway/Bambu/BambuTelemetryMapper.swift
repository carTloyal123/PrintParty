//
//  BambuTelemetryMapper.swift
//  printparty-gateway
//
//  Identical to the iOS BambuTelemetryMapper.swift. Parses Bambu MQTT
//  report JSON and merges into PrintJobState.
//

import Foundation
import PrintPartyKit

enum BambuTelemetryMapper {

    static func merge(payload data: Data, into state: PrintJobState) -> PrintJobState {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            var s = state; s.updatedAt = Date(); return s
        }
        guard let report = envelope.print else {
            var s = state; s.updatedAt = Date(); return s
        }

        var s = state
        let previousStage = s.stage

        if let raw = report.gcode_state {
            let next = mapStage(raw)
            if next.isActive && !previousStage.isActive {
                s.jobId = UUID()
                s.startedAt = Date()
            }
            s.stage = next
        }
        if let pct = report.mc_percent {
            s.progressPercent = max(0, min(100, Double(pct)))
        }
        if let minutes = report.mc_remaining_time, minutes >= 0 {
            s.estimatedEndAt = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        }
        if let name = report.subtask_name, !name.isEmpty { s.jobName = name }
        if let layer = report.layer_num { s.currentLayer = layer }
        if let total = report.total_layer_num, total > 0 { s.totalLayers = total }
        if let t = report.nozzle_temper { s.nozzleTempC = t }
        if let t = report.nozzle_target_temper { s.nozzleTargetC = t }
        if let t = report.bed_temper { s.bedTempC = t }
        if let t = report.bed_target_temper { s.bedTargetC = t }
        if let stg = report.stg_cur { s.substageMessage = substageName(forStgCur: stg) }

        if let hms = report.hms, let first = hms.first {
            s.errorCode = String(format: "HMS_%04X_%04X_%04X_%04X",
                                 first.attr ?? 0, first.code ?? 0, first.flag ?? 0, first.severity ?? 0)
            s.errorMessage = "Bambu HMS alert."
        } else if s.stage != .failed {
            s.errorCode = nil; s.errorMessage = nil
        }

        s.updatedAt = Date()
        return s
    }

    static func mapStage(_ raw: String) -> PrinterStage {
        switch raw.uppercased() {
        case "IDLE": return .idle
        case "PREPARE": return .preparing
        case "RUNNING": return .printing
        case "PAUSE": return .paused
        case "FINISH", "FINISHED": return .done
        case "FAILED": return .failed
        default: return .idle
        }
    }

    static func substageName(forStgCur code: Int) -> String? {
        switch code {
        case 0: return nil
        case 1: return "Auto bed leveling"
        case 2: return "Heatbed preheating"
        case 7: return "Heating hotend"
        case 8: return "Calibrating extrusion"
        case 9: return "Scanning bed surface"
        case 10: return "Inspecting first layer"
        case 12: return "Calibrating Micro Lidar"
        case 13: return "Homing toolhead"
        case 14: return "Cleaning nozzle tip"
        case 18: return "Calibrating extrusion flow"
        case 21: return "Unloading filament"
        case 23: return "Loading filament"
        case 24: return "Calibrating motor noise"
        case 255: return nil
        default: return nil
        }
    }

    private struct Envelope: Decodable { let print: PrintReport? }
    private struct PrintReport: Decodable {
        var gcode_state: String?
        var mc_percent: Int?
        var mc_remaining_time: Int?
        var subtask_name: String?
        var layer_num: Int?
        var total_layer_num: Int?
        var nozzle_temper: Double?
        var nozzle_target_temper: Double?
        var bed_temper: Double?
        var bed_target_temper: Double?
        var hms: [HMSEntry]?
        var stg_cur: Int?
    }
    private struct HMSEntry: Decodable {
        var attr: UInt32?; var code: UInt32?; var flag: UInt32?; var severity: UInt32?
    }
}
