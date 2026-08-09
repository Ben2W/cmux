import Foundation

/// Admission result for one pane-scoped agent runtime mutation.
struct AgentRuntimeMutationOrderingDecision {
    let isAccepted: Bool
    let retainedEventTime: TimeInterval?
}

struct AgentRuntimeMutationOrdering {
    static func decision(
        statusKey: String,
        lifecycleEventTime: TimeInterval?,
        statusEventTime: TimeInterval?,
        replacementWatermark: TimeInterval?,
        hasLifecycleState: Bool,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool,
        isLifecycleMutation: Bool
    ) -> AgentRuntimeMutationOrderingDecision {
        guard enforceOrdering else {
            return AgentRuntimeMutationOrderingDecision(
                isAccepted: true,
                retainedEventTime: nil
            )
        }
        if let replacementWatermark {
            guard let agentEventTime, agentEventTime > replacementWatermark else {
                return AgentRuntimeMutationOrderingDecision(
                    isAccepted: false,
                    retainedEventTime: nil
                )
            }
        }
        if let orderingWatermark = [lifecycleEventTime, statusEventTime]
            .compactMap({ $0 })
            .max() {
            guard let agentEventTime, agentEventTime >= orderingWatermark else {
                return AgentRuntimeMutationOrderingDecision(
                    isAccepted: false,
                    retainedEventTime: nil
                )
            }
        }
        let retainsDurableLifecycleWatermark =
            AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey)
            || isLifecycleMutation
            || hasLifecycleState
        return AgentRuntimeMutationOrderingDecision(
            isAccepted: true,
            retainedEventTime: retainsDurableLifecycleWatermark ? agentEventTime : nil
        )
    }
}

/// Ordered teardown for agent runtime state shared by socket and internal cleanup paths.
extension Workspace {
    @discardableResult
    func clearAgentPID(
        key: String,
        panelId: UUID? = nil,
        clearStatus: Bool = false,
        requireOwnedKey: Bool = false,
        agentEventTime: TimeInterval? = nil,
        enforceAgentEventOrdering: Bool = false,
        refreshPorts: Bool = true
    ) -> Bool {
        let ownedPanelId = agentPIDPanelIdsByKey[key]
        if requireOwnedKey, ownedPanelId == nil {
            return false
        }
        if let panelId, let ownedPanelId, ownedPanelId != panelId {
            return false
        }
        let lifecyclePanelId = ownedPanelId ?? panelId
        let lifecycleStatusKey = agentStatusKey(forAgentPIDKey: key)
        guard acceptAgentRuntimeMutation(
            statusKey: lifecycleStatusKey,
            panelId: lifecyclePanelId,
            agentEventTime: agentEventTime,
            enforceOrdering: enforceAgentEventOrdering
        ) else { return false }
        let statusKeyToClear = clearStatus ? lifecycleStatusKey : nil

        var didChange = false
        if agentPIDs.removeValue(forKey: key) != nil {
            didChange = true
        }
        if agentPIDProcessIdentitiesByKey.removeValue(forKey: key) != nil {
            didChange = true
        }
        if ownedPanelId != nil {
            removeAgentPIDOwnership(key: key)
            didChange = true
        }
        if let changedPanelId = lifecyclePanelId, didChange {
            AgentHibernationController.shared.recordAgentProcessChange(
                workspaceId: id,
                panelId: changedPanelId
            )
        }
        if let lifecyclePanelId,
           clearAgentLifecycle(key: lifecycleStatusKey, panelId: lifecyclePanelId) {
            didChange = true
        }
        if let statusKeyToClear,
           !hasAgentRuntime(forStatusKey: statusKeyToClear),
           let statusEntry = statusEntries[statusKeyToClear],
           statusEntry.agentOwnerPanelID == nil || statusEntry.agentOwnerPanelID == lifecyclePanelId,
           statusEntries.removeValue(forKey: statusKeyToClear) != nil {
            didChange = true
        }
        if didChange, refreshPorts {
            refreshTrackedAgentPorts()
        }
        return didChange
    }

    /// Applies the shared per-agent, per-pane event watermark used by status,
    /// lifecycle, PID, notification, and teardown mutations.
    @discardableResult
    func acceptAgentRuntimeMutation(
        statusKey: String,
        panelId: UUID?,
        agentEventTime: TimeInterval?,
        enforceOrdering: Bool,
        isLifecycleMutation: Bool = false
    ) -> Bool {
        guard enforceOrdering, let panelId else { return true }
        let lifecycleEventTime = agentLifecycleEventTimesByPanelId[panelId]?[statusKey]
        let statusEventTime = statusEntries[statusKey].flatMap { entry in
            entry.agentOwnerPanelID == nil || entry.agentOwnerPanelID == panelId
                ? entry.agentEventTime
                : nil
        }
        let replacementWatermark = AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusKey)
            ? structuredAgentReplacementWatermark(
                panelId: panelId,
                excludingStatusKey: statusKey
            )
            : nil
        let decision = AgentRuntimeMutationOrdering.decision(
            statusKey: statusKey,
            lifecycleEventTime: lifecycleEventTime,
            statusEventTime: statusEventTime,
            replacementWatermark: replacementWatermark,
            hasLifecycleState: agentLifecycleStatesByPanelId[panelId]?[statusKey] != nil,
            agentEventTime: agentEventTime,
            enforceOrdering: true,
            isLifecycleMutation: isLifecycleMutation
        )
        guard decision.isAccepted else { return false }
        if let retainedEventTime = decision.retainedEventTime {
            if let current = agentLifecycleEventTimesByPanelId[panelId]?[statusKey] {
                if retainedEventTime > current {
                    agentLifecycleEventTimesByPanelId[panelId, default: [:]][statusKey] = retainedEventTime
                }
            } else {
                agentLifecycleEventTimesByPanelId[panelId, default: [:]][statusKey] = retainedEventTime
            }
        }
        return true
    }

    private func structuredAgentReplacementWatermark(
        panelId: UUID,
        excludingStatusKey statusKey: String
    ) -> TimeInterval? {
        let lifecycleWatermarks = (agentLifecycleEventTimesByPanelId[panelId] ?? [:]).compactMap { entry in
            entry.key != statusKey && AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(entry.key)
                ? entry.value
                : nil
        }
        let statusWatermarks: [TimeInterval] = statusEntries.compactMap { statusEntry -> TimeInterval? in
            guard statusEntry.key != statusKey,
                  AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(statusEntry.key),
                  statusEntry.value.agentOwnerPanelID == nil || statusEntry.value.agentOwnerPanelID == panelId else {
                return nil
            }
            return statusEntry.value.agentEventTime
        }
        return (lifecycleWatermarks + statusWatermarks).max()
    }
}
