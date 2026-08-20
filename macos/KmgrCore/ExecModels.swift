import Foundation

/// One UID-pinned Pod exec target. Resource-list launches leave the container
/// unspecified so the authoritative Pod snapshot can choose a sensible
/// default; a Container subresource row preserves its exact container name.
public struct PodExecTarget: Hashable, Sendable {
    public var pod: ResourceIdentity
    public var preferredContainer: String?

    public init(
        pod: ResourceIdentity,
        preferredContainer: String? = nil
    ) {
        self.pod = pod
        self.preferredContainer = preferredContainer
    }
}

public struct NodeShellTarget: Hashable, Sendable {
    public var node: ResourceIdentity

    public init(node: ResourceIdentity) {
        self.node = node
    }
}

public struct PodExecDestination: Hashable, Sendable {
    public var pod: ResourceIdentity
    public var container: String

    public init(pod: ResourceIdentity, container: String) {
        self.pod = pod
        self.container = container
    }
}

public struct NodeShellDestination: Hashable, Sendable {
    public var node: ResourceIdentity
    public var namespace: String
    public var image: String

    public init(node: ResourceIdentity, namespace: String, image: String) {
        self.node = node
        self.namespace = namespace
        self.image = image
    }
}

public enum ExecSessionTarget: Hashable, Sendable {
    case pod(PodExecDestination)
    case nodeShell(NodeShellDestination)

    public var identity: ResourceIdentity {
        switch self {
        case .pod(let destination): destination.pod
        case .nodeShell(let destination): destination.node
        }
    }

    public var operationDescription: String {
        switch self {
        case .pod: "exec Pod"
        case .nodeShell: "open Node shell"
        }
    }
}

public struct TerminalSize: Hashable, Sendable {
    public var columns: UInt32
    public var rows: UInt32

    public init(columns: UInt32, rows: UInt32) {
        precondition(columns > 0 && rows > 0)
        self.columns = columns
        self.rows = rows
    }
}

public struct ExecSessionRequest: Hashable, Sendable {
    public var sessionID: String
    public var execSessionID: String
    public var generation: UInt64
    public var target: ExecSessionTarget
    public var contextName: String
    public var clusterName: String
    public var command: [String]
    public var tty: Bool
    public var stdin: Bool
    public var initialSize: TerminalSize?

    public init(
        sessionID: String,
        execSessionID: String,
        generation: UInt64,
        target: ExecSessionTarget,
        contextName: String,
        clusterName: String = "",
        command: [String],
        tty: Bool = true,
        stdin: Bool = true,
        initialSize: TerminalSize? = TerminalSize(columns: 80, rows: 24)
    ) {
        self.sessionID = sessionID
        self.execSessionID = execSessionID
        self.generation = generation
        self.target = target
        self.contextName = contextName
        self.clusterName = clusterName
        self.command = command
        self.tty = tty
        self.stdin = stdin
        self.initialSize = initialSize
    }
}

public enum ExecConnectionState: String, Hashable, Sendable {
    case connecting
    case running
    case exited
    case cancelled
    case failed

    public var isTerminal: Bool {
        self == .exited || self == .cancelled || self == .failed
    }
}

public struct ExecStatus: Hashable, Sendable {
    public var state: ExecConnectionState
    public var exitCode: Int32?
    public var statusReason: String
    public var issue: ClusterManagerIssue?

    public init(
        state: ExecConnectionState,
        exitCode: Int32? = nil,
        statusReason: String = "",
        issue: ClusterManagerIssue? = nil
    ) {
        self.state = state
        self.exitCode = exitCode
        self.statusReason = statusReason
        self.issue = issue
    }
}

public enum ExecServerEvent: Hashable, Sendable {
    case stdout(cursor: StreamCursor, data: Data)
    case stderr(cursor: StreamCursor, data: Data)
    case status(cursor: StreamCursor, status: ExecStatus)
    case failure(cursor: StreamCursor, issue: ClusterManagerIssue)

    public var cursor: StreamCursor {
        switch self {
        case .stdout(let cursor, _), .stderr(let cursor, _),
            .status(let cursor, _), .failure(let cursor, _):
            cursor
        }
    }
}

public protocol ExecSession: Sendable {
    var events: AsyncThrowingStream<ExecServerEvent, Error> { get }
    func sendStdin(_ data: Data) async throws
    func resize(_ size: TerminalSize) async throws
    func closeStdin() async throws
    func cancel() async
}

public protocol ExecSessionProviding: Sendable {
    func startExec(request: ExecSessionRequest) async throws -> any ExecSession
}
