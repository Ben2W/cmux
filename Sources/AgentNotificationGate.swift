import CmuxControlSocket
import Foundation

/// Category an agent hook attaches to a notification so the app can gate
/// delivery by user config. Mirrors the CLI's `ClaudeNotifyCategory`; serialized
/// into the `notify_target_async` payload's optional legacy or ordered metadata.
enum AgentNotifyCategory: String {
    case turnComplete = "turn-complete"
    case needsPermission = "needs-permission"
    case idleReminder = "idle-reminder"
    case other
}

/// User policy for the "Claude finished a turn" notification.
enum AgentTurnCompleteMode: String {
    case whenIdle
    case always
    case never
}

/// Parsed agent notification metadata. Legacy two-field policy tags remain
/// valid; cmux-owned hooks add canonical `k=<status-key>;t=<event-time>` fields
/// so delivery can advance the shared per-pane ordering watermark.
struct AgentNotificationMeta {
    let category: AgentNotifyCategory
    let pending: Bool
    let agentKind: String?
    let isSubagent: Bool?
    let agentStatusKey: String?
    let agentEventTime: TimeInterval?

    init?(meta: String) {
        let fields = meta.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 2,
              fields[0].hasPrefix("c="),
              fields[1].hasPrefix("p=") else { return nil }
        guard let known = AgentNotifyCategory(rawValue: String(fields[0].dropFirst(2))) else { return nil }
        switch fields[1].dropFirst(2) {
        case "1": self.pending = true
        case "0": self.pending = false
        default: return nil
        }
        var parsedAgentKind: String?
        var parsedIsSubagent: Bool?
        var parsedStatusKey: String?
        var parsedEventTime: TimeInterval?
        for field in fields.dropFirst(2) {
            if field.hasPrefix("a=") {
                guard parsedAgentKind == nil else { return nil }
                let value = String(field.dropFirst(2))
                guard Self.isValidAgentKindTag(value) else { return nil }
                parsedAgentKind = value
            } else if field.hasPrefix("n=") {
                guard parsedIsSubagent == nil else { return nil }
                switch field.dropFirst(2) {
                case "1": parsedIsSubagent = true
                case "0": parsedIsSubagent = false
                default: return nil
                }
            } else if field.hasPrefix("k=") {
                guard parsedStatusKey == nil else { return nil }
                let value = String(field.dropFirst(2))
                guard !value.isEmpty,
                      value.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return nil }
                parsedStatusKey = value
            } else if field.hasPrefix("t=") {
                guard parsedEventTime == nil,
                      let value = TimeInterval(field.dropFirst(2)),
                      value.isPlausibleControlAgentEventTime else { return nil }
                parsedEventTime = value
            } else {
                return nil
            }
        }
        guard (parsedStatusKey == nil) == (parsedEventTime == nil) else { return nil }
        guard known != .other || parsedStatusKey != nil else { return nil }
        self.category = known
        self.agentKind = parsedAgentKind
        self.isSubagent = parsedIsSubagent
        self.agentStatusKey = parsedStatusKey
        self.agentEventTime = parsedEventTime
    }

    /// Mirror of the CLI's `AgentHookNotifyCategory.isValidAgentKindTag` slug
    /// grammar: 1-64 characters of `[a-z0-9._-]`. Both sides must agree
    /// exactly or the meta folds back into the notification body.
    static func isValidAgentKindTag(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber
                    || character == "." || character == "_" || character == "-")
        }
    }
}

/// Pure delivery decision for agent-tagged notifications. Kept free of any I/O
/// so it can be exhaustively unit-tested against the decision table.
nonisolated func agentNotificationShouldDeliver(
    category: AgentNotifyCategory,
    pending: Bool,
    permissionEnabled: Bool,
    turnMode: AgentTurnCompleteMode,
    idleEnabled: Bool
) -> Bool {
    switch category {
    case .needsPermission:
        return permissionEnabled
    case .turnComplete:
        switch turnMode {
        case .always: return true
        case .never: return false
        case .whenIdle: return !pending
        }
    case .idleReminder:
        return idleEnabled && !pending
    case .other:
        // Legacy/uncategorized (codex, grok, antigravity, pre-meta clients):
        // deliver exactly as before.
        return true
    }
}
