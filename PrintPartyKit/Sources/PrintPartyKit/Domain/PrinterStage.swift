//
//  PrinterStage.swift
//  PrintParty
//
//  Normalized stages that every printer adapter must map to.
//  This is the contract the Live Activity UI is built against —
//  nothing vendor-specific should leak past this enum.
//

import Foundation

public enum PrinterStage: String, Codable, Sendable, CaseIterable, Hashable {
    case idle
    case preparing      // heating bed/nozzle, homing, etc.
    case printing
    case paused
    case finishing      // retract, park, cooldown
    case done
    case failed
    case canceled
    case offline        // adapter lost contact while job was active

    public var isActive: Bool {
        switch self {
        case .preparing, .printing, .paused, .finishing:
            return true
        case .idle, .done, .failed, .canceled, .offline:
            return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .canceled:
            return true
        default:
            return false
        }
    }
}
