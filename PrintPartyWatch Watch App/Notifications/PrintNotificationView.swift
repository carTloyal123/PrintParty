//
//  PrintNotificationView.swift
//  PrintPartyWatch Watch App
//
//  Custom long-look notification UI for print events (done / failed) that the
//  phone forwards to the watch. Registered via `WKNotificationScene` in the App
//  scene for the "PRINT_EVENT" category.
//
//  The iPhone/gateway sets these optional keys in the APNs payload so the watch
//  can render a richer card than the default text:
//    aps.alert.title / body          — standard
//    printparty.stage                — PrinterStage raw value (e.g. "done")
//    printparty.printer              — printer display name
//    printparty.progress             — 0...100 (Double, optional)
//

import SwiftUI
import UserNotifications
import WatchKit
import PrintPartyKit

struct PrintNotificationView: View {
    let title: String
    let message: String
    let stage: PrinterStage
    let printerName: String?
    let progress: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: stage.symbolName)
                    .font(.title3)
                    .foregroundStyle(stage.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    if let printerName {
                        Text(printerName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if let progress {
                ProgressView(value: min(max(progress / 100, 0), 1))
                    .tint(stage.tint)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}

/// Hosting controller that maps an incoming `UNNotification` to the SwiftUI view.
final class PrintNotificationController: WKUserNotificationHostingController<PrintNotificationView> {

    private var title = ""
    private var message = ""
    private var stage: PrinterStage = .done
    private var printerName: String?
    private var progress: Double?

    override func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        title = content.title.isEmpty ? "Print Update" : content.title
        message = content.body
        printerName = content.userInfo["printparty.printer"] as? String

        if let raw = content.userInfo["printparty.stage"] as? String,
           let parsed = PrinterStage(rawValue: raw) {
            stage = parsed
        }
        if let value = content.userInfo["printparty.progress"] as? Double {
            progress = value
        } else if let value = content.userInfo["printparty.progress"] as? NSNumber {
            progress = value.doubleValue
        }
    }

    override var body: PrintNotificationView {
        PrintNotificationView(
            title: title,
            message: message,
            stage: stage,
            printerName: printerName,
            progress: progress
        )
    }
}
