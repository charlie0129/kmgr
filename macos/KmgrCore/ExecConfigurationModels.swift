import Foundation

public enum ExecContainerKind: String, Hashable, Sendable {
    case regular
    case ephemeral
    case initContainer

    fileprivate var sortOrder: Int {
        switch self {
        case .regular: 0
        case .ephemeral: 1
        case .initContainer: 2
        }
    }

    public var displaySuffix: String {
        switch self {
        case .regular: ""
        case .ephemeral: " — Ephemeral"
        case .initContainer: " — Init"
        }
    }
}

public struct ExecContainerCandidate: Hashable, Sendable {
    public var name: String
    public var kind: ExecContainerKind

    public init(name: String, kind: ExecContainerKind) {
        self.name = name
        self.kind = kind
    }

    public var displayTitle: String { name + kind.displaySuffix }
}

/// Extracts the bounded, display-safe container summary returned by the
/// authoritative object GET. A name is offered once, preferring a regular
/// container if malformed input repeats it across container groups.
public enum ExecContainerCatalog {
    public static func orderedDetails(
        from values: [PodContainerDetail]
    ) -> [PodContainerDetail] {
        var byName: [String: PodContainerDetail] = [:]
        for value in values {
            guard !value.name.isEmpty, value.name.utf8.count <= 253,
                !value.name.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                })
            else { continue }
            if let existing = byName[value.name],
                existing.kind.sortOrder <= value.kind.sortOrder
            {
                continue
            }
            byName[value.name] = value
        }
        return byName.values.sorted { lhs, rhs in
            if lhs.kind.sortOrder != rhs.kind.sortOrder {
                return lhs.kind.sortOrder < rhs.kind.sortOrder
            }
            return lhs.name < rhs.name
        }
    }

    public static func candidates(
        from values: [PodContainerDetail]
    ) -> [ExecContainerCandidate] {
        orderedDetails(from: values).map {
            ExecContainerCandidate(name: $0.name, kind: $0.kind)
        }
    }

    public static func candidates(from fields: [ObjectSummaryField]) -> [ExecContainerCandidate] {
        var byName: [String: ExecContainerCandidate] = [:]
        for field in fields where field.sectionID == "containers" {
            guard let parsed = candidate(from: field), parsed.name.utf8.count <= 253 else { continue }
            if let existing = byName[parsed.name], existing.kind.sortOrder <= parsed.kind.sortOrder {
                continue
            }
            byName[parsed.name] = parsed
        }
        return byName.values.sorted { lhs, rhs in
            if lhs.kind.sortOrder != rhs.kind.sortOrder {
                return lhs.kind.sortOrder < rhs.kind.sortOrder
            }
            return lhs.name < rhs.name
        }
    }

    /// Chooses from the authoritative summary while preserving Pod spec order.
    /// Kubernetes' conventional default-container annotation wins when it names
    /// an eligible container. Without it, a regular container is preferred to
    /// an ephemeral or init container.
    public static func automaticCandidate(
        from fields: [ObjectSummaryField],
        defaultContainerName: String? = nil
    ) -> ExecContainerCandidate? {
        let candidateByName = Dictionary(
            uniqueKeysWithValues: candidates(from: fields).map { ($0.name, $0) }
        )
        var ordered: [ExecContainerCandidate] = []
        var seenNames = Set<String>()
        for field in fields where field.sectionID == "containers" {
            guard let parsed = candidate(from: field),
                seenNames.insert(parsed.name).inserted,
                let preferredKind = candidateByName[parsed.name]
            else { continue }
            ordered.append(preferredKind)
        }
        if let defaultContainerName,
            let annotated = ordered.first(where: { $0.name == defaultContainerName })
        {
            return annotated
        }
        return ordered.first(where: { $0.kind == .regular })
            ?? ordered.first(where: { $0.kind == .ephemeral })
            ?? ordered.first(where: { $0.kind == .initContainer })
    }

    private static func candidate(from field: ObjectSummaryField) -> ExecContainerCandidate? {
        let mappings: [(prefix: String, kind: ExecContainerKind)] = [
            ("container:", .regular),
            ("ephemeralContainer:", .ephemeral),
            ("initContainer:", .initContainer),
        ]
        for mapping in mappings where field.fieldID.hasPrefix(mapping.prefix) {
            let name = String(field.fieldID.dropFirst(mapping.prefix.count))
            guard !name.isEmpty, field.displayText == name,
                !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return ExecContainerCandidate(name: name, kind: mapping.kind)
        }
        return nil
    }
}

public struct AutomaticExecLaunchPlan: Hashable, Sendable {
    public var request: ExecSessionRequest
    public var fallbackShellCommand: [String]?

    public init(
        request: ExecSessionRequest,
        fallbackShellCommand: [String]?
    ) {
        self.request = request
        self.fallbackShellCommand = fallbackShellCommand
    }
}

public enum AutomaticExecLaunchPlanner {
    public static let defaultContainerAnnotation =
        "kubectl.kubernetes.io/default-container"

    /// Produces the exact first exec request from a fresh, UID-authoritative
    /// Pod detail. The helper independently repeats the UID check immediately
    /// before opening Kubernetes' exec stream.
    public static func plan(
        session: OpenedClusterSession,
        target: PodExecTarget,
        detail: ObjectDetail,
        initialSize: TerminalSize = .defaultShellWindow,
        execSessionID: String
    ) throws -> AutomaticExecLaunchPlan {
        let pod = target.pod
        guard pod.clusterSessionID == session.sessionID,
            pod.group.isEmpty,
            pod.version == "v1",
            pod.resource == "pods",
            !pod.namespace.isEmpty,
            !pod.name.isEmpty,
            !pod.uid.rawValue.isEmpty
        else { throw AutomaticExecLaunchError.invalidPodIdentity }
        guard detail.identity == pod else {
            throw AutomaticExecLaunchError.objectIdentityMismatch
        }
        guard !execSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomaticExecLaunchError.invalidExecSessionID
        }

        let candidate: ExecContainerCandidate
        if let preferred = target.preferredContainer {
            guard !preferred.isEmpty,
                let selected = ExecContainerCatalog.candidates(
                    from: detail.summaryFields
                ).first(where: { $0.name == preferred })
            else {
                throw AutomaticExecLaunchError.preferredContainerUnavailable(preferred)
            }
            candidate = selected
        } else {
            let annotated = detail.annotations[defaultContainerAnnotation]
            guard let selected = ExecContainerCatalog.automaticCandidate(
                from: detail.summaryFields,
                defaultContainerName: annotated
            ) else { throw AutomaticExecLaunchError.noEligibleContainer }
            candidate = selected
        }

        let request = ExecSessionRequest(
            sessionID: session.sessionID,
            execSessionID: execSessionID,
            generation: 1,
            target: .pod(PodExecDestination(pod: pod, container: candidate.name)),
            contextName: session.contextName,
            clusterName: session.clusterName,
            command: ["/bin/bash"],
            initialSize: initialSize
        )
        return AutomaticExecLaunchPlan(
            request: request,
            fallbackShellCommand: ["/bin/sh"]
        )
    }
}

public struct NodeShellLaunchPlan: Hashable, Sendable {
    public var request: ExecSessionRequest
    public var fallbackShellCommand: [String]?

    public init(request: ExecSessionRequest, fallbackShellCommand: [String]?) {
        self.request = request
        self.fallbackShellCommand = fallbackShellCommand
    }
}

public enum NodeShellLaunchPlanner {
    public static func plan(
        session: OpenedClusterSession,
        target: NodeShellTarget,
        image: String,
        namespace: String,
        command: [String] = ["bash", "-l"],
        fallbackShellCommand: [String]? = ["sh", "-l"],
        initialSize: TerminalSize = .defaultShellWindow,
        execSessionID: String
    ) throws -> NodeShellLaunchPlan {
        let node = target.node
        guard node.clusterSessionID == session.sessionID,
            node.group.isEmpty,
            node.version == "v1",
            node.resource == "nodes",
            node.namespace.isEmpty,
            !node.name.isEmpty,
            !node.uid.rawValue.isEmpty
        else { throw NodeShellLaunchError.invalidNodeIdentity }
        guard NodeShellPreferences.isValidImage(image) else {
            throw NodeShellLaunchError.invalidImage
        }
        guard isValidNamespace(namespace) else {
            throw NodeShellLaunchError.invalidNamespace
        }
        guard !execSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NodeShellLaunchError.invalidExecSessionID
        }
        let validatedCommand = try ExecCommandChoice.executable(
            path: command.first ?? "",
            arguments: Array(command.dropFirst())
        ).validatedCommand()
        let request = ExecSessionRequest(
            sessionID: session.sessionID,
            execSessionID: execSessionID,
            generation: 1,
            target: .nodeShell(NodeShellDestination(
                node: node,
                namespace: namespace,
                image: image
            )),
            contextName: session.contextName,
            clusterName: session.clusterName,
            command: validatedCommand,
            initialSize: initialSize
        )
        return NodeShellLaunchPlan(
            request: request,
            fallbackShellCommand: fallbackShellCommand
        )
    }

    public static func defaultNamespace(for session: OpenedClusterSession) -> String {
        let value = session.defaultNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidNamespace(value) ? value : "default"
    }

    public static func isValidNamespace(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 63,
            let first = bytes.first, let last = bytes.last,
            isLowercaseLetterOrDigit(first),
            isLowercaseLetterOrDigit(last)
        else { return false }
        return bytes.allSatisfy { byte in
            isLowercaseLetterOrDigit(byte) || byte == 0x2d
        }
    }

    private static func isLowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39)
    }
}

public enum NodeShellLaunchError: Error, Hashable, Sendable {
    case invalidNodeIdentity
    case invalidImage
    case invalidNamespace
    case invalidExecSessionID
}

extension NodeShellLaunchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidNodeIdentity:
            "Node shell requires one complete, UID-pinned core/v1 Node from this cluster session."
        case .invalidImage:
            "Enter a nonempty helper image reference without whitespace or control characters."
        case .invalidNamespace:
            "The helper namespace must be a lowercase Kubernetes namespace name of at most 63 characters."
        case .invalidExecSessionID:
            "The terminal session identifier is invalid."
        }
    }
}

public enum AutomaticExecLaunchError: Error, Hashable, Sendable {
    case invalidPodIdentity
    case objectIdentityMismatch
    case invalidExecSessionID
    case noEligibleContainer
    case preferredContainerUnavailable(String)
}

extension AutomaticExecLaunchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPodIdentity:
            "Terminal exec requires one complete, UID-pinned Pod from this cluster session."
        case .objectIdentityMismatch:
            "The authoritative refresh returned a different Kubernetes object."
        case .invalidExecSessionID:
            "The terminal session identifier is invalid."
        case .noEligibleContainer:
            "The selected Pod declares no container eligible for terminal exec."
        case .preferredContainerUnavailable(let name):
            "Container \(name.isEmpty ? "(empty)" : name) is no longer present in the selected Pod."
        }
    }
}

public enum ExecCommandChoice: Hashable, Sendable {
    case shell(path: String)
    case executable(path: String, arguments: [String])

    public static let maximumArguments = 256
    public static let maximumUTF8Bytes = 64 << 10

    /// Produces the exact argv sent to Kubernetes. No shell tokenization or
    /// interpolation is performed for an explicit executable.
    public func validatedCommand() throws -> [String] {
        let command: [String]
        switch self {
        case .shell(let path):
            command = [path.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .executable(let path, let arguments):
            command = [path.trimmingCharacters(in: .whitespacesAndNewlines)] + arguments
        }
        guard !command.isEmpty, command.count <= Self.maximumArguments else {
            throw ExecConfigurationValidationError.tooManyArguments
        }
        guard command.allSatisfy(Self.isValidArgument) else {
            throw ExecConfigurationValidationError.invalidArgument
        }
        guard command.reduce(into: 0, { $0 += $1.utf8.count }) <= Self.maximumUTF8Bytes else {
            throw ExecConfigurationValidationError.commandTooLarge
        }
        return command
    }

    /// The UI uses one argument per line so spaces remain part of an argument
    /// and quoting is never ambiguously interpreted by a hidden shell.
    public static func arguments(onePerLine text: String) -> [String] {
        text.split(whereSeparator: \Character.isNewline).compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    private static func isValidArgument(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\0") &&
            !value.unicodeScalars.contains(where: {
                $0.value == 0x0a || $0.value == 0x0d
            })
    }
}

public enum ExecConfigurationValidationError: Error, Hashable, Sendable {
    case invalidArgument
    case tooManyArguments
    case commandTooLarge
}

extension ExecConfigurationValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidArgument:
            "Executable and arguments must be non-empty and cannot contain line breaks or NUL bytes."
        case .tooManyArguments:
            "A command may contain at most \(ExecCommandChoice.maximumArguments) executable and argument values."
        case .commandTooLarge:
            "The executable and arguments may contain at most \(ExecCommandChoice.maximumUTF8Bytes) UTF-8 bytes."
        }
    }
}
