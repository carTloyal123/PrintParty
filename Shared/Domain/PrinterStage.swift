//
//  PrinterStage.swift
//  PrintParty
//
//  Normalized stages that every printer adapter must map to.
//  This is the contract the Live Activity UI is built against —
//  nothing vendor-specific should leak past this enum.
//

import Foundation
import SwiftUI

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

    public var displayName: String {
        switch self {
        case .idle:       return "Idle"
        case .preparing:  return "Preparing"
        case .printing:   return "Printing"
        case .paused:     return "Paused"
        case .finishing:  return "Finishing"
        case .done:       return "Done"
        case .failed:     return "Failed"
        case .canceled:   return "Canceled"
        case .offline:    return "Offline"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle:       return "moon.zzz"
        case .preparing:  return "flame"
        case .printing:   return "printer.fill"
        case .paused:     return "pause.circle.fill"
        case .finishing:  return "checkmark.circle"
        case .done:       return "checkmark.seal.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .canceled:   return "xmark.circle.fill"
        case .offline:    return "wifi.slash"
        }
    }

    public var tint: Color {
        switch self {
        case .idle:       return .secondary
        case .preparing:  return .orange
        case .printing:   return .blue
        case .paused:     return .yellow
        case .finishing:  return .mint
        case .done:       return .green
        case .failed:     return .red
        case .canceled:   return .gray
        case .offline:    return .red
        }
    }
}
