//
//  PrintPartyWatchWidgetExtensionBundle.swift
//  PrintPartyWatchWidgetExtension
//
//  Created by Carson Loyal on 6/7/26.
//

import WidgetKit
import SwiftUI

@main
struct PrintPartyWatchWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        PrintPartyWatchWidgetExtension()
        PrintPartyWatchWidgetExtensionControl()
    }
}
