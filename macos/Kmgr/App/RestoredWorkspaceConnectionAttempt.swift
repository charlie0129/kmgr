import Foundation
import KmgrCore

/// Owns one cancellable asynchronous context-open attempt for a workspace that
/// has already been presented. UI creation is intentionally outside this type,
/// so a slow provider can never delay the restored window.
@MainActor
final class RestoredWorkspaceConnectionAttempt {
    private let provider: any ClusterContextProviding
    private let contextReference: String
    private var task: Task<Void, Never>?

    var onOpened: ((OpenedClusterSession) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onFinish: (() -> Void)?

    init(
        provider: any ClusterContextProviding,
        contextReference: String
    ) {
        self.provider = provider
        self.contextReference = contextReference
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        let provider = provider
        let contextReference = contextReference
        task = Task { [weak self] in
            let result: Result<OpenedClusterSession, Error>
            do {
                result = .success(try await provider.openContext(reference: contextReference))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            task = nil
            switch result {
            case .success(let session): onOpened?(session)
            case .failure(let error): onFailure?(error)
            }
            onFinish?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
