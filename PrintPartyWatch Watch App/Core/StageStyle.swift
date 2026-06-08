//
//  StageStyle.swift
//  PrintPartyWatch Watch App
//
//  SwiftUI presentation for `PrinterStage`. Mirrors the iOS app's
//  `PrinterStage+UI` extension (in Shared/), duplicated here because that file
//  is not a member of the watch target and the mapping can't live in
//  PrintPartyKit (the Linux gateway imports the package and has no SwiftUI).
//

import SwiftUI
import PrintPartyKit

extension PrinterStage {

    var displayName: String {
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

    var symbolName: String {
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

    var tint: Color {
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
