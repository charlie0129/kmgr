import Foundation
import KmgrCore

struct WorkspaceStatus: Hashable, Sendable {
    enum Severity: Int, Hashable, Sendable, Comparable {
        case informational
        case warning
        case error

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var text: String
    var severity: Severity
    var busy: Bool
    var toolTip: String?
    var shortText: String?

    init(
        _ text: String,
        severity: Severity = .informational,
        busy: Bool = false,
        toolTip: String? = nil,
        shortText: String? = nil
    ) {
        self.text = text
        self.severity = severity
        self.busy = busy
        self.toolTip = toolTip
        self.shortText = shortText
    }
}

@MainActor
protocol WorkspaceStatusPublishing: AnyObject {
    var workspaceStatus: WorkspaceStatus { get }
    var onWorkspaceStatusChanged: ((WorkspaceStatus) -> Void)? { get set }
}

/// Independent status channels let connection health remain visible while the
/// active surface, discovery, or a workspace operation reports its own state.
/// `warmCache` is intentionally reserved for the authority cache stream.
enum WorkspaceStatusSource: Hashable, Sendable {
    case content
    case discovery
    case namespace
    case workspaceOperation
    case warmCache
}

struct WorkspaceStatusBoard: Hashable, Sendable {
    private var statuses: [WorkspaceStatusSource: WorkspaceStatus] = [:]

    mutating func set(_ status: WorkspaceStatus?, for source: WorkspaceStatusSource) {
        statuses[source] = status
    }

    func status(for source: WorkspaceStatusSource) -> WorkspaceStatus? {
        statuses[source]
    }

    var presented: WorkspaceStatus {
        let immediate = statuses.filter { source, status in
            source == .workspaceOperation
                || (source != .content && status.busy)
        }
        if let content = statuses[.content], content.severity == .error,
            !immediate.isEmpty
        {
            return content
        }
        if let status = highest(in: immediate) { return status }

        if let content = statuses[.content] {
            let supplements = statuses.filter { source, status in
                source != .content
                    && source != .workspaceOperation
                    && !status.busy
                    && (source == .warmCache || status.severity > .informational)
            }.sorted { lhs, rhs in
                presentationRank(lhs) > presentationRank(rhs)
            }
            return supplements.isEmpty
                ? content
                : composed(content: content, supplements: supplements)
        }

        return highest(in: statuses) ?? WorkspaceStatus("Ready")
    }

    private func highest(
        in candidates: [WorkspaceStatusSource: WorkspaceStatus]
    ) -> WorkspaceStatus? {
        candidates.max { lhs, rhs in
            presentationRank(lhs) < presentationRank(rhs)
        }?.value
    }

    private func composed(
        content: WorkspaceStatus,
        supplements: [Dictionary<WorkspaceStatusSource, WorkspaceStatus>.Element]
    ) -> WorkspaceStatus {
        let statuses = [content] + supplements.map(\.value)
        return WorkspaceStatus(
            ([content.text] + supplements.map { $0.value.shortText ?? $0.value.text })
                .joined(separator: " · "),
            severity: statuses.map(\.severity).max() ?? content.severity,
            busy: content.busy,
            toolTip: statuses.map { status in
                guard let toolTip = status.toolTip, toolTip != status.text else {
                    return status.text
                }
                return "\(status.text)\n\(toolTip)"
            }.joined(separator: "\n\n")
        )
    }

    private func presentationRank(
        _ entry: Dictionary<WorkspaceStatusSource, WorkspaceStatus>.Element
    ) -> (Int, Int, Int) {
        (
            entry.value.severity.rawValue,
            entry.value.busy ? 1 : 0,
            sourceRank(entry.key, status: entry.value)
        )
    }

    private func sourceRank(
        _ source: WorkspaceStatusSource,
        status: WorkspaceStatus
    ) -> Int {
        switch source {
        case .workspaceOperation: 5
        case .content: 3
        case .discovery: status.busy ? 4 : 2
        case .namespace: 1
        case .warmCache: 0
        }
    }
}

enum WarmCacheWorkspaceStatus {
    static func make(
        authority: WarmCacheUsage,
        global: WarmCacheUsage
    ) -> WorkspaceStatus? {
        guard isAvailable(authority) || isAvailable(global) else { return nil }

        let authorityMemory = memoryUsage(authority)
        let globalMemory = memoryUsage(global)
        let aggregatesDiffer = authority != global
        var components = ["Warm cache \(authorityMemory)"]
        if aggregatesDiffer {
            components.append("global \(globalMemory)")
        }
        components.append(aggregatesDiffer
            ? "evictions \(authority.budgetEvictions.formatted())/\(global.budgetEvictions.formatted())"
            : "\(authority.budgetEvictions.formatted()) evictions")
        let text = components.joined(separator: " · ")

        return WorkspaceStatus(
            text,
            toolTip: [
                detail(title: "This cluster", usage: authority),
                detail(title: "Global warm cache", usage: global),
                "Retained memory is a conservative warm-cache estimate, not total engine memory.",
            ].joined(separator: "\n\n"),
            shortText: text
        )
    }

    private static func isAvailable(_ usage: WarmCacheUsage) -> Bool {
        usage.viewLimit > 0 || usage.objectLimit > 0 || usage.byteLimit > 0
    }

    private static func memoryUsage(_ usage: WarmCacheUsage) -> String {
        "\(bytes(usage.retainedBytes)) / \(bytes(usage.byteLimit))"
    }

    private static func detail(title: String, usage: WarmCacheUsage) -> String {
        """
        \(title)
        \(usage.retainedViews.formatted()) / \(usage.viewLimit.formatted()) queries
        \(usage.retainedObjects.formatted()) / \(usage.objectLimit.formatted()) objects
        \(memoryUsage(usage)) estimated retained memory
        \(usage.budgetEvictions.formatted()) budget evictions
        """
    }

    private static func bytes(_ count: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var scaled = Double(count)
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        if unit == 0 { return "\(count.formatted()) B" }
        if scaled.rounded() == scaled || scaled >= 10 {
            return String(format: "%.0f %@", scaled, units[unit])
        }
        return String(format: "%.1f %@", scaled, units[unit])
    }
}
