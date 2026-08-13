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
