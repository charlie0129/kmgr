import Foundation

/// The resource identity needed to offer deterministic filter completions.
///
/// Completion is deliberately independent of live rows and Kubernetes schema
/// discovery. That keeps typing work bounded even for very large lists and
/// still permits a few useful exact paths for built-in resource kinds.
public struct ResourceFilterCompletionContext: Hashable, Sendable {
    public var gvr: GVR
    public var namespaced: Bool

    public init(gvr: GVR, namespaced: Bool) {
        self.gvr = gvr
        self.namespaced = namespaced
    }

    public init(resource: DiscoveredResource) {
        self.init(
            gvr: GVR(
                group: resource.group,
                version: resource.version,
                resource: resource.resource
            ),
            namespaced: resource.namespaced
        )
    }
}

/// A small best-effort catalog for the resource-list filter grammar.
///
/// Returned strings are replacements for `partialWordRange`, matching
/// AppKit's text-completion delegate contract. The range is expressed in
/// UTF-16 code units; malformed, out-of-bounds, or grapheme-splitting ranges
/// are rejected rather than repaired into a different edit.
public enum ResourceFilterCompletionCatalog {
    public static let maximumResults = 24

    public static func completions(
        in expression: String,
        partialWordRange: NSRange,
        context: ResourceFilterCompletionContext
    ) -> [String] {
        guard let token = tokenContext(
            in: expression,
            partialWordRange: partialWordRange
        ) else { return [] }

        let fieldPaths = fieldPaths(for: context)
        let candidates: [String]
        let caseSensitive: Bool
        switch token.prefix.lowercased() {
        case "":
            // Full field terms are included here so a native completion panel
            // opened on the first character can keep filtering its bounded
            // list while the user continues through `field:metadata.`.
            candidates = [
                "namespace:", "name:", "ns:", "status:", "label:",
            ] + fieldPaths.map { "field:\($0)" } + ["field:"]
            caseSensitive = false
        case "field:":
            // AppKit normally excludes `field:` from its partial-word range,
            // so return only the path that should replace that range.
            candidates = fieldPaths
            caseSensitive = true
        default:
            return []
        }

        return Array(candidates.lazy.filter { candidate in
            if caseSensitive {
                return candidate != token.partial && candidate.hasPrefix(token.partial)
            }
            return candidate.caseInsensitiveCompare(token.partial) != .orderedSame
                && candidate.lowercased().hasPrefix(token.partial.lowercased())
        }.prefix(maximumResults))
    }

    private struct TokenContext {
        var prefix: String
        var partial: String
    }

    private static func tokenContext(
        in expression: String,
        partialWordRange: NSRange
    ) -> TokenContext? {
        let utf16Count = expression.utf16.count
        guard partialWordRange.location != NSNotFound,
            partialWordRange.location >= 0,
            partialWordRange.length >= 0,
            partialWordRange.location <= utf16Count,
            partialWordRange.length <= utf16Count - partialWordRange.location,
            let partialRange = Range(partialWordRange, in: expression)
        else { return nil }

        var tokenStart = expression.startIndex
        var index = expression.startIndex
        var quote: Character?
        var isEscaped = false
        while index < partialRange.lowerBound {
            let character = expression[index]
            let next = expression.index(after: index)
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                tokenStart = next
            }
            index = next
        }

        guard !isEscaped, quote == nil else { return nil }
        let prefix = String(expression[tokenStart..<partialRange.lowerBound])
        let partial = String(expression[partialRange])
        guard !partial.isEmpty,
            !prefix.contains("\\"), !prefix.contains("\""), !prefix.contains("'"),
            !partial.contains("\\"), !partial.contains("\""), !partial.contains("'"),
            !partial.contains(where: \.isWhitespace),
            !prefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            !partial.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return TokenContext(prefix: prefix, partial: partial)
    }

    private static func fieldPaths(
        for context: ResourceFilterCompletionContext
    ) -> [String] {
        var paths = ["metadata.name"]
        if context.namespaced { paths.append("metadata.namespace") }
        paths += [
            "metadata.uid",
            "metadata.resourceVersion",
            "metadata.creationTimestamp",
            "metadata.generation",
            "metadata.deletionTimestamp",
            "metadata.generateName",
            "metadata.deletionGracePeriodSeconds",
        ]

        let gvr = context.gvr
        switch (gvr.group, gvr.version, gvr.resource) {
        case ("", "v1", "pods"):
            paths += [
                "spec.nodeName",
                "spec.serviceAccountName",
                "spec.schedulerName",
                "status.phase",
                "status.podIP",
                "status.hostIP",
                "status.qosClass",
            ]
        case ("", "v1", "nodes"):
            paths += [
                "spec.providerID",
                "spec.podCIDR",
                "status.nodeInfo.kubeletVersion",
                "status.nodeInfo.osImage",
                "status.nodeInfo.operatingSystem",
                "status.nodeInfo.architecture",
            ]
        case ("", "v1", "services"):
            paths += [
                "spec.type",
                "spec.clusterIP",
                "spec.externalName",
                "spec.loadBalancerIP",
            ]
        case ("", "v1", "namespaces"):
            paths.append("status.phase")
        case ("apps", "v1", "deployments"):
            paths += [
                "spec.replicas",
                "spec.paused",
                "status.observedGeneration",
                "status.replicas",
                "status.readyReplicas",
                "status.availableReplicas",
            ]
        case ("apps", "v1", "statefulsets"):
            paths += [
                "spec.replicas",
                "spec.serviceName",
                "status.observedGeneration",
                "status.replicas",
                "status.readyReplicas",
                "status.currentRevision",
            ]
        case ("apps", "v1", "daemonsets"):
            paths += [
                "status.observedGeneration",
                "status.desiredNumberScheduled",
                "status.currentNumberScheduled",
                "status.updatedNumberScheduled",
                "status.numberReady",
                "status.numberAvailable",
            ]
        case ("apps", "v1", "replicasets"):
            paths += [
                "spec.replicas",
                "status.observedGeneration",
                "status.replicas",
                "status.readyReplicas",
                "status.availableReplicas",
            ]
        case ("batch", "v1", "jobs"):
            paths += [
                "spec.parallelism",
                "spec.completions",
                "status.active",
                "status.succeeded",
                "status.failed",
            ]
        case ("batch", "v1", "cronjobs"):
            paths += [
                "spec.schedule",
                "spec.suspend",
                "status.lastScheduleTime",
                "status.lastSuccessfulTime",
            ]
        default:
            break
        }
        return paths
    }
}
