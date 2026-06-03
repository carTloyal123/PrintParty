//
//  PrintPartyLiveActivity.swift
//  PrintPartyWidgetExtension
//
//  Declares the Live Activity widget and routes ContentState updates to the
//  Lock Screen banner and Dynamic Island presentations.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct PrintPartyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintPartyActivityAttributes.self) { context in
            // Lock Screen / Banner / standby view.
            LockScreenLiveActivityView(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded layout — visible when user long-presses.
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(
                        attributes: context.attributes,
                        state: context.state
                    )
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(state: context.state)
                }
            } compactLeading: {
                CompactLeadingView(state: context.state)
            } compactTrailing: {
                CompactTrailingView(state: context.state)
            } minimal: {
                MinimalView(state: context.state)
            }
            .widgetURL(URL(string: "printparty://printer/\(context.attributes.printerId.uuidString)"))
            .keylineTint(context.state.stage.tint)
        }
    }
}
