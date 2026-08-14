import Foundation

/// A bounded, display-safe rendering of an error for compact AppKit surfaces.
///
/// `ClusterManagerIssue` contains useful structured context that is lost when
/// callers use only `localizedDescription`. This value keeps that context while
/// bounding every server-controlled string and the final composed text.
public struct UserFacingErrorPresentation: Hashable, Sendable {
    public static let maximumTitleCharacters = 120
    public static let maximumMessageCharacters = 480
    public static let maximumMetadataCharacters = 480
    public static let maximumCauseCharacters = 200
    public static let maximumPresentedCauses = 3
    public static let maximumInlineCharacters = 1_600
    public static let maximumDetailedCharacters = 2_000

    public let title: String
    public let message: String
    public let metadata: String
    public let causes: [String]

    public init(_ issue: ClusterManagerIssue) {
        let title = Self.bounded(
            Self.title(for: issue.category),
            limit: Self.maximumTitleCharacters,
            fallback: "Kubernetes request failed"
        )
        self.title = title
        self.message = Self.bounded(
            issue.message,
            limit: Self.maximumMessageCharacters,
            fallback: title
        )

        var metadataParts: [String] = []
        Self.appendMetadata("Operation", value: issue.operation, to: &metadataParts)
        Self.appendMetadata("Context", value: issue.contextName, to: &metadataParts)
        Self.appendMetadata("Reason", value: issue.reason, to: &metadataParts)
        if let statusReason = issue.kubernetesStatus?.reason,
            !statusReason.isEmpty,
            statusReason != issue.reason
        {
            Self.appendMetadata("API reason", value: statusReason, to: &metadataParts)
        }
        if let status = issue.httpStatusCode, status > 0 {
            metadataParts.append("HTTP \(status)")
        }
        if issue.retryable {
            if let delay = Self.retryDelayText(for: issue) {
                metadataParts.append("Retryable after \(delay)")
            } else {
                metadataParts.append("Retryable")
            }
        } else {
            metadataParts.append("Not retryable")
        }
        self.metadata = Self.bounded(
            metadataParts.joined(separator: " · "),
            limit: Self.maximumMetadataCharacters
        )

        let renderedCauses = (issue.kubernetesStatus?.causes ?? []).compactMap(Self.causeText)
        var causes = renderedCauses.prefix(Self.maximumPresentedCauses).map { $0 }
        if renderedCauses.count > Self.maximumPresentedCauses {
            causes.append("+\(renderedCauses.count - Self.maximumPresentedCauses) more causes")
        }
        self.causes = causes
    }

    public init(_ error: any Error) {
        if let issue = error as? ClusterManagerIssue {
            self = Self(issue)
        } else {
            title = "Error"
            message = Self.bounded(
                error.localizedDescription,
                limit: Self.maximumMessageCharacters,
                fallback: "The operation failed."
            )
            metadata = ""
            causes = []
        }
    }

    /// Text for an inline status label. It includes structured context and a
    /// compact cause summary, then applies a final defensive bound.
    public var inlineText: String {
        Self.bounded(
            [message, supplementaryText].filter { !$0.isEmpty }.joined(separator: " · "),
            limit: Self.maximumInlineCharacters,
            fallback: title
        )
    }

    /// Context suitable for a secondary label or tooltip.
    public var supplementaryText: String {
        var parts = [metadata].filter { !$0.isEmpty }
        if !causes.isEmpty {
            parts.append("Causes: " + causes.joined(separator: "; "))
        }
        return Self.bounded(
            parts.joined(separator: " · "),
            limit: Self.maximumInlineCharacters
        )
    }

    /// A multiline form for tooltips and larger issue panels.
    public var detailedText: String {
        var lines = [title, message]
        if !metadata.isEmpty { lines.append(metadata) }
        if !causes.isEmpty {
            lines.append("Causes:")
            lines.append(contentsOf: causes.map { "• \($0)" })
        }
        return Self.bounded(
            lines.filter { !$0.isEmpty }.joined(separator: "\n"),
            limit: Self.maximumDetailedCharacters,
            preservingNewlines: true,
            fallback: title
        )
    }

    private static func appendMetadata(
        _ label: String,
        value: String,
        to parts: inout [String]
    ) {
        let value = bounded(value, limit: 160)
        if !value.isEmpty { parts.append("\(label): \(value)") }
    }

    private static func title(for category: ClusterManagerIssue.Category) -> String {
        switch category {
        case .authentication: "Authentication failed"
        case .authorization: "Access denied"
        case .notFound: "Not found"
        case .conflict: "Conflict"
        case .validation: "Validation failed"
        case .unavailable: "Cluster unavailable"
        case .timeout: "Request timed out"
        case .cancelled: "Request cancelled"
        case .tls: "TLS connection failed"
        case .unsupported: "Unsupported operation"
        case .internalFailure: "Kmgr engine error"
        case .resourceExhausted: "Resource limit reached"
        }
    }

    private static func retryDelayText(for issue: ClusterManagerIssue) -> String? {
        if let milliseconds = issue.retryAfterMilliseconds, milliseconds > 0 {
            if milliseconds < 1_000 { return "\(milliseconds) ms" }
            let seconds = Double(milliseconds) / 1_000
            return seconds.formatted(.number.precision(.fractionLength(0...1))) + " s"
        }
        if let seconds = issue.kubernetesStatus?.retryAfterSeconds, seconds > 0 {
            return "\(seconds) s"
        }
        return nil
    }

    private static func causeText(_ cause: ClusterManagerIssue.KubernetesStatus.Cause) -> String? {
        var prefix: [String] = []
        let field = bounded(cause.field, limit: 100)
        let reason = bounded(cause.reason, limit: 100)
        let message = bounded(cause.message, limit: Self.maximumCauseCharacters)
        if !field.isEmpty { prefix.append("Field \(field)") }
        if !reason.isEmpty { prefix.append(reason) }
        guard !prefix.isEmpty || !message.isEmpty else { return nil }
        let rendered = prefix.joined(separator: " · ")
            + (!prefix.isEmpty && !message.isEmpty ? ": " : "")
            + message
        return bounded(rendered, limit: Self.maximumCauseCharacters)
    }

    private static func bounded(
        _ value: String,
        limit: Int,
        preservingNewlines: Bool = false,
        fallback: String = ""
    ) -> String {
        var sanitized = ""
        sanitized.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                if preservingNewlines, scalar == "\n" || scalar == "\r" {
                    sanitized.append("\n")
                } else {
                    sanitized.append(" ")
                }
            } else {
                sanitized.unicodeScalars.append(scalar)
            }
        }
        let normalized: String
        if preservingNewlines {
            normalized = sanitized
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        } else {
            normalized = sanitized
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        let candidate = normalized.isEmpty ? fallback : normalized
        guard candidate.count > limit else { return candidate }
        guard limit > 1 else { return String(candidate.prefix(limit)) }
        return String(candidate.prefix(limit - 1)) + "…"
    }
}

public extension ClusterManagerIssue {
    var userFacingPresentation: UserFacingErrorPresentation {
        UserFacingErrorPresentation(self)
    }
}
