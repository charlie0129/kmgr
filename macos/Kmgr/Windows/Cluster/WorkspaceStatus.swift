import Foundation

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
            let issues = statuses.filter { source, status in
                source != .content
                    && source != .workspaceOperation
                    && !status.busy
                    && status.severity > .informational
            }.sorted { lhs, rhs in
                presentationRank(lhs) > presentationRank(rhs)
            }
            return issues.isEmpty ? content : composed(content: content, issues: issues)
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
        issues: [Dictionary<WorkspaceStatusSource, WorkspaceStatus>.Element]
    ) -> WorkspaceStatus {
        let statuses = [content] + issues.map(\.value)
        return WorkspaceStatus(
            ([content.text] + issues.map { $0.value.shortText ?? $0.value.text })
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
