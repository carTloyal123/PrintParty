//
//  LiveActivityCoordinator.swift
//  PrintParty
//
//  Bridges AdapterRegistry state changes to ActivityKit lifecycle calls.
//
//  Key invariant: at most ONE Live Activity per printerId at any time.
//  On launch, we adopt any activities left over from a previous session
//  (iOS keeps them alive across app relaunches) and end any orphans.
//

import Foundation
import ActivityKit
import Observation
import PrintPartyKit

@MainActor
@Observable
final class LiveActivityCoordinator {

    static let shared = LiveActivityCoordinator()

    /// Map of printerId → live Activity handle.
    private var activities: [UUID: Activity<PrintPartyActivityAttributes>] = [:]

    /// When each activity was started. Used to enforce a minimum keep-alive
    /// so the push token has time to arrive before auto-end kicks in.
    private var activityStartedAt: [UUID: Date] = [:]

    /// Minimum time an activity must live after creation before auto-end
    /// can dismiss it. Apple needs several seconds to issue a push token.
    private static let minimumKeepAlive: TimeInterval = 30

    /// Latest state delivered via APNs push for each printer. Polled from
    /// activity.content.state in the reconcile loop every second.
    private(set) var pushDeliveredStates: [UUID: PrintJobState] = [:]

    /// Last ContentState we pushed per printer, for debouncing.
    private var lastPushedState: [UUID: PrintJobState] = [:]

    /// Minimum interval between non-stage-change updates.
    private static let minimumUpdateInterval: TimeInterval = 2.0
    private var lastPushedAt: [UUID: Date] = [:]

    /// Whether auto-dismiss is enabled after a print finishes.
    /// When false, the activity stays until the user manually toggles it off.
    static let lingerEnabledKey = "liveActivity.lingerEnabled"

    /// Duration (in seconds) to keep a Live Activity visible after a print
    /// reaches a terminal state (done/failed/canceled).
    static let lingerDurationKey = "liveActivity.lingerDurationSeconds"
    static let defaultLingerDuration: TimeInterval = 300 // 5 minutes

    private var isLingerEnabled: Bool {
        // Default to true if never set.
        if UserDefaults.standard.object(forKey: Self.lingerEnabledKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: Self.lingerEnabledKey)
    }

    private var lingerDuration: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.lingerDurationKey)
        return stored > 0 ? stored : Self.defaultLingerDuration
    }

    /// Per-printer opt-out. Stores UUIDs (as strings) of printers the user
    /// has disabled Live Activities for. When disabled, auto-start is
    /// suppressed and any running activity is ended immediately.
    ///
    /// The toggle in PrinterDetailView controls two things:
    ///   - **ON**: Removes from disabled set and force-starts an activity
    ///     with the current state. Normal lifecycle takes over from there:
    ///     updates flow during a print, and the configured linger duration
    ///     applies when the print finishes (even if the user toggled it on
    ///     mid-print).
    ///   - **OFF**: Adds to disabled set and ends the activity immediately.
    static let disabledPrinterIdsKey = "liveActivity.disabledPrinterIds"

    private var disabledPrinterIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.disabledPrinterIdsKey) ?? [])
    }

    private func isLiveActivityEnabled(for printerId: UUID) -> Bool {
        !disabledPrinterIds.contains(printerId.uuidString)
    }

    /// Toggle the Live Activity for a specific printer.
    ///
    /// - **ON**: Force-starts an activity with the current state (even if
    ///   idle or done). Normal lifecycle takes over immediately — if the
    ///   printer is idle or finished, the activity will show for the
    ///   configured linger duration then auto-dismiss. If the printer is
    ///   mid-print, updates flow normally and linger applies at the end.
    ///
    /// - **OFF**: Immediately ends any running activity and suppresses
    ///   auto-start until re-enabled.
    func setLiveActivityEnabled(_ enabled: Bool, for printerId: UUID) async {
        var ids = disabledPrinterIds
        if enabled {
            ids.remove(printerId.uuidString)
        } else {
            ids.insert(printerId.uuidString)
        }
        UserDefaults.standard.set(Array(ids), forKey: Self.disabledPrinterIdsKey)

        if !enabled {
            await endActivity(for: printerId)
        } else {
            // Force-start an activity with whatever state is current.
            let registry = AdapterRegistry.shared
            for (_, state) in registry.states {
                if state.printerId == printerId {
                    if activities[printerId] == nil {
                        // If the print already finished and auto-dismiss is on,
                        // check whether the linger window has already elapsed.
                        // No point starting an activity that should already be gone.
                        if (state.stage.isTerminal || state.stage == .idle) && isLingerEnabled {
                            let elapsed = Date.now.timeIntervalSince(state.updatedAt)
                            if elapsed >= lingerDuration {
                                break // linger window already passed
                            }
                        }
                        start(state: state)
                    }
                    break
                }
            }
        }
    }

    /// Whether Live Activities are enabled for a printer (user hasn't
    /// opted out). This controls auto-start permission, not whether an
    /// activity is currently showing.
    func liveActivityEnabled(for printerId: UUID) -> Bool {
        isLiveActivityEnabled(for: printerId)
    }

    /// Whether a Live Activity is currently running for this printer.
    func hasRunningActivity(for printerId: UUID) -> Bool {
        activities[printerId] != nil
    }

    /// Returns the latest state delivered via APNs push for a printer,
    /// if a Live Activity is running and has received at least one push.
    /// Used by AdapterRegistry as a fallback when the WebSocket is offline.
    func pushState(for printerId: UUID) -> PrintJobState? {
        pushDeliveredStates[printerId]
    }

    /// Tasks observing pushTokenUpdates per gateway-backed activity.
    private var pushTokenTasks: [UUID: Task<Void, Never>] = [:]

    private var tickTask: Task<Void, Never>?

    private init() {
        // Adopt any activities from a previous app session first.
        adoptExistingActivities()

        // Safety-net polling loop.
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.reconcile()
            }
        }
    }

    // MARK: - Adopt existing activities on launch

    /// On app launch, iOS may still have Live Activities from a previous
    /// session. Adopt the ones we recognize and end any orphans.
    private func adoptExistingActivities() {
        let existing = Activity<PrintPartyActivityAttributes>.activities
        if existing.isEmpty { return }

        print("[LiveActivityCoordinator] Found \(existing.count) existing activity(ies) from previous session")

        for activity in existing {
            let printerId = activity.attributes.printerId

            if activities[printerId] == nil {
                // Adopt this activity — we'll update or end it in the next reconcile.
                activities[printerId] = activity
                print("[LiveActivityCoordinator] Adopted activity for printer \(printerId)")
            } else {
                // Duplicate for a printer we already track — end it.
                Task {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    print("[LiveActivityCoordinator] Ended duplicate activity for printer \(printerId)")
                }
            }
        }
    }

    // MARK: Reconciliation

    /// Event-driven entry point. The AdapterRegistry calls this on every
    /// state update.
    func notify(state: PrintJobState) {
        handle(state: state, printerId: state.printerId)
    }

    private func reconcile() {
        let registry = AdapterRegistry.shared

        // Poll each running activity's current content and push it into
        // the registry as fallback state. This is more reliable than the
        // contentUpdates async stream, which may not emit when the app
        // transitions between foreground/background. The Activity object's
        // `content` property is always up-to-date with the latest push.
        for (printerId, activity) in activities {
            let pushState = activity.content.state
            pushDeliveredStates[printerId] = pushState
            registry.ingestPushState(pushState)
        }

        // Build a set of "live" printer IDs using state.printerId (the ID
        // the Live Activity is keyed on). For gateway printers this is the
        // remotePrinterId, NOT the local SwiftData Printer.id.
        var livePrinterIds = Set<UUID>()
        for (_, state) in registry.states {
            livePrinterIds.insert(state.printerId)
            handle(state: state, printerId: state.printerId)
        }

        // Clean up activities for printers that are no longer registered.
        // This catches the case where a printer was removed while its
        // activity was still running — the state disappears from the
        // registry but the activity handle lingers in our dict.
        for printerId in activities.keys {
            if !livePrinterIds.contains(printerId) {
                if let activity = activities[printerId] {
                    Task { await activity.end(nil, dismissalPolicy: .immediate) }
                }
                activities[printerId] = nil
                activityStartedAt[printerId] = nil
                lastPushedState[printerId] = nil
                lastPushedAt[printerId] = nil
                pushTokenTasks[printerId]?.cancel()
                pushTokenTasks[printerId] = nil
            }
        }
    }

    private func handle(state: PrintJobState, printerId: UUID) {
        let existing = activities[printerId]

        switch (existing, state.stage) {
        case (nil, let stage) where stage.isActive:
            if isLiveActivityEnabled(for: printerId) {
                start(state: state)
            }

        case (let activity?, let stage) where stage.isActive:
            update(activity: activity, state: state)

        case (let activity?, let stage) where stage.isTerminal || stage == .idle:
            // Enforce a minimum keep-alive so the push token has time to
            // arrive from Apple before we tear the activity down.
            if let startedAt = activityStartedAt[printerId],
               Date.now.timeIntervalSince(startedAt) < Self.minimumKeepAlive {
                // Still within the grace period — just update the content
                // so the UI reflects the current state; don't end yet.
                update(activity: activity, state: state)
                return
            }

            if isLingerEnabled {
                // Auto-dismiss: compute remaining linger time from when the
                // state last changed (i.e. when the print actually finished),
                // not from now. If the window already elapsed, dismiss immediately.
                let elapsed = Date.now.timeIntervalSince(state.updatedAt)
                let remaining = lingerDuration - elapsed
                if remaining > 0 {
                    Task { await end(activity: activity, finalState: state, lingerSeconds: remaining) }
                } else {
                    Task { await end(activity: activity, finalState: state, lingerSeconds: 0) }
                }
                activities[printerId] = nil
                activityStartedAt[printerId] = nil
                lastPushedState[printerId] = nil
                lastPushedAt[printerId] = nil
                // NOTE: Don't cancel pushTokenTasks here — the token may
                // still be in flight and we need it for future relay pushes.
                // It gets cleaned up when the printer is unregistered or
                // the activity stream naturally ends.
            } else {
                // Manual mode: keep the activity alive showing the final
                // state. The user dismisses it by toggling the switch off.
                update(activity: activity, state: state)
            }

        default:
            break
        }
    }

    // MARK: ActivityKit calls

    private func start(state: PrintJobState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }

        // CRITICAL: check if there's already a system-level activity for this
        // printer that we don't know about (e.g. from a previous session that
        // wasn't properly adopted). End it before starting a new one.
        let existingSystemActivities = Activity<PrintPartyActivityAttributes>.activities
            .filter { $0.attributes.printerId == state.printerId }
        for stale in existingSystemActivities {
            if activities[state.printerId]?.id != stale.id {
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
                print("[LiveActivityCoordinator] Ended stale system activity for \(state.printerId)")
            }
        }

        let attributes = PrintPartyActivityAttributes(
            printerId: state.printerId,
            printerDisplayName: state.printerDisplayName,
            printerModel: state.printerModel
        )
        let content = ActivityContent(
            state: state,
            staleDate: nil,
            relevanceScore: 100
        )

        let isGateway = isGatewayPrinter(state.printerId)
        print("[LiveActivityCoordinator] isGatewayPrinter(\(state.printerId)): \(isGateway)")
        if !isGateway {
            // Log why — helps debug the adapter lookup
            let adapter = AdapterRegistry.shared.adapter(for: state.printerId)
            print("[LiveActivityCoordinator] adapter lookup for \(state.printerId): \(adapter.map { String(describing: type(of: $0)) } ?? "nil")")
        }

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: isGateway ? .token : nil
            )
            activities[state.printerId] = activity
            activityStartedAt[state.printerId] = .now
            lastPushedState[state.printerId] = state
            lastPushedAt[state.printerId] = .now

            print("[LiveActivityCoordinator] Started activity for \(state.printerDisplayName) (pushType: \(isGateway ? "token" : "none"))")

            if isGateway {
                observePushToken(activity: activity, printerId: state.printerId)
                // Note: push-delivered state is polled in reconcile() via
                // activity.content.state — more reliable than the async
                // contentUpdates stream which can miss updates.
            }
        } catch {
            print("[LiveActivityCoordinator] start failed: \(error)")
        }
    }

    /// Observe pushTokenUpdates on a Live Activity and POST each token
    /// to the gateway's /v1/activities endpoint.
    private func observePushToken(
        activity: Activity<PrintPartyActivityAttributes>,
        printerId: UUID
    ) {
        pushTokenTasks[printerId]?.cancel()
        pushTokenTasks[printerId] = Task {
            print("[LiveActivityCoordinator] observePushToken: waiting for token on activity \(activity.id) for printer \(printerId)...")

            // Check if there's already a token available
            if let existingToken = activity.pushToken {
                let token = existingToken.map { String(format: "%02x", $0) }.joined()
                print("[LiveActivityCoordinator] push token (immediate): \(token.prefix(16))...")
                await forwardPushToken(printerId: printerId, token: token)
            }

            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else {
                    print("[LiveActivityCoordinator] observePushToken: task cancelled for \(printerId)")
                    break
                }
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                print("[LiveActivityCoordinator] push token (update): \(token.prefix(16))...")
                await forwardPushToken(printerId: printerId, token: token)
            }
            print("[LiveActivityCoordinator] observePushToken: stream ended for \(printerId)")
        }
    }

    /// Find the gateway base URL for a printer and POST the token.
    ///
    /// NOTE: We intentionally do NOT send the E2EE shared key here.
    /// The Live Activity's ContentState type is PrintJobState (plaintext).
    /// If we sent the key, the gateway would encrypt the payload and
    /// ActivityKit would fail to decode it. E2EE for push updates requires
    /// changing ContentState to a wrapper type that handles decryption —
    /// planned for a future milestone.
    ///
    /// Tries the WebSocket `activities.register` request via the adapter.
    private func forwardPushToken(printerId: UUID, token: String) async {
        guard let adapter = AdapterRegistry.shared.adapter(for: printerId) as? GatewayAdapter,
              adapter.connectionMode != .disconnected else {
            print("[LiveActivityCoordinator] forwardPushToken: no connected adapter for \(printerId) — token NOT forwarded")
            return
        }

        do {
            struct WSBody: Encodable {
                let printerId: UUID
                let pushToken: String
            }
            let _ = try await adapter.request(
                "activities.register",
                payload: WSBody(printerId: printerId, pushToken: token)
            )
            print("[LiveActivityCoordinator] push token forwarded via WS successfully")
        } catch {
            print("[LiveActivityCoordinator] WS activities.register failed: \(error)")
        }
    }

    private func isGatewayPrinter(_ printerId: UUID) -> Bool {
        AdapterRegistry.shared.adapter(for: printerId) is GatewayAdapter
    }

    private func update(activity: Activity<PrintPartyActivityAttributes>, state: PrintJobState) {
        let printerId = state.printerId
        let previous = lastPushedState[printerId]
        let last = lastPushedAt[printerId] ?? .distantPast

        let stageChanged = previous?.stage != state.stage
        let dueByTime = Date.now.timeIntervalSince(last) >= Self.minimumUpdateInterval
        guard stageChanged || dueByTime else { return }

        let content = ActivityContent(state: state, staleDate: nil, relevanceScore: 100)
        Task {
            await activity.update(content)
            await MainActor.run {
                lastPushedState[printerId] = state
                lastPushedAt[printerId] = .now
            }
        }
    }

    private func end(
        activity: Activity<PrintPartyActivityAttributes>,
        finalState: PrintJobState,
        lingerSeconds: TimeInterval? = nil
    ) async {
        let content = ActivityContent(state: finalState, staleDate: nil, relevanceScore: 0)
        let seconds = lingerSeconds ?? lingerDuration
        let policy: ActivityUIDismissalPolicy = seconds > 0
            ? .after(.now.addingTimeInterval(seconds))
            : .immediate
        await activity.end(content, dismissalPolicy: policy)
    }

    // MARK: - Public API for explicit lifecycle management

    /// End the Live Activity for a specific printer. Called by
    /// AdapterRegistry.unregister() when a printer is removed so the
    /// activity doesn't linger on the lock screen.
    func endActivity(for printerId: UUID) async {
        // End our tracked activity if we have one.
        if let activity = activities[printerId] {
            await activity.end(nil, dismissalPolicy: .immediate)
            activities[printerId] = nil
            activityStartedAt[printerId] = nil
            lastPushedState[printerId] = nil
            lastPushedAt[printerId] = nil
            pushTokenTasks[printerId]?.cancel()
            pushTokenTasks[printerId] = nil
            pushDeliveredStates[printerId] = nil
        }

        // Also sweep system-level activities for this printer in case
        // we lost track of one (e.g. across an app relaunch).
        for activity in Activity<PrintPartyActivityAttributes>.activities {
            if activity.attributes.printerId == printerId {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Force-end every active activity. Useful for debugging.
    func endAll() async {
        // End both our tracked activities AND any system-level ones we missed.
        for activity in Activity<PrintPartyActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activities.removeAll()
        activityStartedAt.removeAll()
        lastPushedState.removeAll()
        lastPushedAt.removeAll()
        for (_, task) in pushTokenTasks { task.cancel() }
        pushTokenTasks.removeAll()
        pushDeliveredStates.removeAll()
        print("[LiveActivityCoordinator] Ended ALL activities")
    }
}
