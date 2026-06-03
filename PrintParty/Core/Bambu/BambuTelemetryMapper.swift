//
//  BambuTelemetryMapper.swift
//  PrintParty
//
//  Parses Bambu Lab MQTT telemetry JSON and merges it into a PrintJobState.
//
//  Bambu's report payloads come in two shapes:
//
//   1. Full state in response to a "pushall" request:
//        { "print": { "gcode_state": "RUNNING", "mc_percent": 42, ... } }
//
//   2. Incremental deltas (printer sends these on every state change):
//        { "print": { "mc_percent": 43 } }
//
//  Either way we union-merge into the last known PrintJobState. Fields that
//  aren't present in the message are simply preserved.
//
//  Other top-level wrappers (`info`, `system`, etc.) exist but we ignore them
//  for now — none contain anything the Live Activity needs.
//

import Foundation

enum BambuTelemetryMapper {

    /// Decode `data` (a UTF-8 JSON object) and apply it to `state`.
    /// Returns the merged state. If the payload doesn't include a `print`
    /// section, the input is returned unchanged (other than `updatedAt`).
    static func merge(payload data: Data, into state: PrintJobState) -> PrintJobState {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            // Unknown JSON shape — preserve state, bump updatedAt to keep the
            // adapter heartbeat fresh.
            var s = state
            s.updatedAt = .now
            return s
        }

        guard let report = envelope.print else {
            var s = state
            s.updatedAt = .now
            return s
        }

        var s = state
        let previousStage = s.stage

        if let raw = report.gcode_state {
            let next = mapStage(raw)
            // Synthesize a job boundary on transitions out of idle / into active.
            if next.isActive && !previousStage.isActive {
                s.jobId = UUID()
                s.startedAt = .now
            }
            s.stage = next
        }

        if let pct = report.mc_percent {
            s.progressPercent = max(0, min(100, Double(pct)))
        }

        if let minutes = report.mc_remaining_time, minutes >= 0 {
            // mc_remaining_time is reported in MINUTES on Bambu printers.
            s.estimatedEndAt = Date.now.addingTimeInterval(TimeInterval(minutes) * 60)
        }

        if let name = report.subtask_name, !name.isEmpty {
            s.jobName = name
        }

        if let layer = report.layer_num { s.currentLayer = layer }
        if let total = report.total_layer_num, total > 0 { s.totalLayers = total }

        if let t = report.nozzle_temper        { s.nozzleTempC   = t }
        if let t = report.nozzle_target_temper { s.nozzleTargetC = t }
        if let t = report.bed_temper           { s.bedTempC      = t }
        if let t = report.bed_target_temper    { s.bedTargetC    = t }

        // Fine-grained substage. Only present when the printer is doing
        // something more specific than "Printing" / "Preparing".
        if let stg = report.stg_cur {
            s.substageMessage = substageName(forStgCur: stg)
        }

        // Surface the first non-OK HMS code as a freeform error message.
        if let hms = report.hms, let first = hms.first {
            s.errorCode = String(
                format: "HMS_%04X_%04X_%04X_%04X",
                first.attr ?? 0, first.code ?? 0, first.flag ?? 0, first.severity ?? 0
            )
            s.errorMessage = "Bambu HMS alert (see printer screen for details)."
        } else if s.stage != .failed {
            s.errorCode = nil
            s.errorMessage = nil
        }

        s.updatedAt = .now
        return s
    }

    static func mapStage(_ raw: String) -> PrinterStage {
        switch raw.uppercased() {
        case "IDLE":               return .idle
        case "PREPARE":            return .preparing
        case "RUNNING":            return .printing
        case "PAUSE":              return .paused
        case "FINISH", "FINISHED": return .done
        case "FAILED":             return .failed
        default:                   return .idle
        }
    }

    /// Map Bambu's `stg_cur` substage code to a human-readable string.
    /// Returns nil for codes that don't add information beyond the top-level
    /// stage (0 = generic printing, 255 = idle, anything unknown).
    ///
    /// Code list compiled from community reverse-engineering of the X1C / P1 /
    /// A1 firmware report packets. Some codes are A1-specific; unknown values
    /// fall through to nil so we just show the universal stage name.
    static func substageName(forStgCur code: Int) -> String? {
        switch code {
        case 0:   return nil
        case 1:   return "Auto bed leveling"
        case 2:   return "Heatbed preheating"
        case 3:   return "Sweeping XY mech mode"
        case 4:   return "Changing filament"
        case 5:   return "M400 pause"
        case 6:   return "Paused \u{2014} filament runout"
        case 7:   return "Heating hotend"
        case 8:   return "Calibrating extrusion"
        case 9:   return "Scanning bed surface"
        case 10:  return "Inspecting first layer"
        case 11:  return "Identifying build plate"
        case 12:  return "Calibrating Micro Lidar"
        case 13:  return "Homing toolhead"
        case 14:  return "Cleaning nozzle tip"
        case 15:  return "Checking extruder temperature"
        case 16:  return "Paused by user"
        case 17:  return "Paused \u{2014} front cover open"
        case 18:  return "Calibrating extrusion flow"
        case 19:  return "Paused \u{2014} nozzle temperature error"
        case 20:  return "Paused \u{2014} heat bed temperature error"
        case 21:  return "Unloading filament"
        case 22:  return "Paused \u{2014} skipped steps"
        case 23:  return "Loading filament"
        case 24:  return "Calibrating motor noise"
        case 25:  return "Paused \u{2014} AMS lost"
        case 26:  return "Paused \u{2014} heat-break fan slow"
        case 27:  return "Paused \u{2014} chamber temperature error"
        case 28:  return "Cooling chamber"
        case 29:  return "Paused by user G-code"
        case 30:  return "Calibrating motor noise"
        case 31:  return "Paused \u{2014} nozzle filament covered"
        case 32:  return "Paused \u{2014} cutter error"
        case 33:  return "Paused \u{2014} first layer error"
        case 34:  return "Paused \u{2014} nozzle clog"
        case 255: return nil
        default:  return nil
        }
    }

    // MARK: - Codable shapes

    private struct Envelope: Decodable {
        let print: PrintReport?
    }

    /// Subset of the Bambu `print` object we care about. snake_case property
    /// names match the wire format exactly; CodingKeys are derived
    /// automatically. Every field is optional because the printer sends
    /// partial deltas.
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
        var print_error: Int?
        var hms: [HMSEntry]?
        /// Bambu fine-grained "current substage" code. See `substageName(forStgCur:)`.
        var stg_cur: Int?
    }

    private struct HMSEntry: Decodable {
        var attr: UInt32?
        var code: UInt32?
        var flag: UInt32?
        var severity: UInt32?
    }
}
