//
//  PrintPartyWidgetExtensionBundle.swift
//  PrintPartyWidgetExtension
//
//  Entry point for the widget extension. The only widget we ship today is the
//  Live Activity for an in-progress print. (A future Home Screen widget could
//  show a printer's current state at a glance; not implemented yet.)
//

import WidgetKit
import SwiftUI

@main
struct PrintPartyWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        PrintPartyLiveActivity()
    }
}
