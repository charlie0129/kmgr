import Foundation

private let frameBookmarkIdentifierCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
)

private func isValidFrameBookmarkIdentifier(_ value: String) -> Bool {
    !value.isEmpty
        && value.utf8.count <= ClusterWindowRestorationRecord.maximumIdentifierBytes
        && !value.unicodeScalars.contains(where: {
            !frameBookmarkIdentifierCharacters.contains($0)
        })
}

/// The durable metadata for one exact kubeconfig context's reusable window
/// frame. The frame is stored as raw global coordinates so AppKit cannot
/// remap an unavailable display before Kmgr validates it.
public struct WorkspaceFrameBookmark: Hashable, Codable, Sendable, Identifiable {
    public static let maximumContextReferenceBytes =
        ClusterWindowRestorationState.maximumContextNameBytes
    public static let maximumIdentifierBytes =
        ClusterWindowRestorationRecord.maximumIdentifierBytes

    public var id: String
    public var contextReference: String
    public var sourceWindowID: String?
    public var frame: WorkspaceWindowFrame?

    public init(
        id: String = UUID().uuidString.lowercased(),
        contextReference: String,
        sourceWindowID: String? = nil,
        frame: WorkspaceWindowFrame? = nil
    ) {
        self.id = id
        self.contextReference = contextReference
        self.sourceWindowID = sourceWindowID
        self.frame = frame
    }

    public func validated() throws -> Self {
        var issues: [RestorationValidationIssue] = []
        if !isValidFrameBookmarkIdentifier(id) {
            issues.append(.init(
                path: "id",
                message: "A frame bookmark ID must be a bounded opaque identifier."
            ))
        }
        if contextReference.isEmpty
            || contextReference.utf8.count > Self.maximumContextReferenceBytes
            || contextReference.contains("\0")
        {
            issues.append(.init(
                path: "contextReference",
                message: "A frame bookmark context reference must be bounded and non-empty."
            ))
        }
        if let sourceWindowID, !isValidFrameBookmarkIdentifier(sourceWindowID) {
            issues.append(.init(
                path: "sourceWindowID",
                message: "A frame bookmark source must be a bounded opaque window identifier."
            ))
        }
        if let frame, !frame.isValid {
            issues.append(.init(
                path: "frame",
                message: "A frame bookmark must contain finite coordinates and positive bounded dimensions."
            ))
        }
        guard issues.isEmpty else {
            throw RestorationValidationError(issues: issues)
        }
        return self
    }
}

public struct WorkspaceFrameBookmarkLoadIssue: Error, LocalizedError, Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        case unsupportedVersion
        case invalidData
        case invalidValues
    }

    public var reason: Reason
    public var message: String

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Strict, bounded metadata for reusable exact-context frame bookmarks. The
/// store deliberately has its own UserDefaults document so adding frame
/// persistence cannot invalidate the existing navigation restoration document.
@MainActor
public final class WorkspaceFrameBookmarkStore {
    public static let apiVersion = "kmgr.workspace-frame-bookmarks/v1"
    public static let storageKey = "kmgr.workspace-frame-bookmarks.document"
    public static let maximumBookmarks = 64
    public static let maximumDocumentBytes = 256 << 10

    private struct Document: Codable {
        var apiVersion: String
        var bookmarks: [WorkspaceFrameBookmark]
    }

    private struct DocumentHeader: Decodable {
        var apiVersion: String
    }

    private let defaults: UserDefaults

    public private(set) var bookmarks: [WorkspaceFrameBookmark] = []
    public private(set) var loadIssue: WorkspaceFrameBookmarkLoadIssue?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFromDefaults()
    }

    public func bookmark(for contextReference: String) -> WorkspaceFrameBookmark? {
        bookmarks.first { $0.contextReference == contextReference }
    }

    /// Makes a window the source of the reusable frame for an exact context.
    /// The bookmark identity is retained when the source changes. A `nil`
    /// frame preserves an existing frame and is useful when seeding metadata
    /// from an older restoration record that has no coordinates.
    @discardableResult
    public func activate(
        contextReference: String,
        sourceWindowID: String,
        frame: WorkspaceWindowFrame? = nil
    ) throws -> WorkspaceFrameBookmark {
        let proposed = WorkspaceFrameBookmark(
            contextReference: contextReference,
            sourceWindowID: sourceWindowID,
            frame: frame
        )
        guard contextReference.utf8.count <= WorkspaceFrameBookmark.maximumContextReferenceBytes,
            !contextReference.isEmpty,
            !contextReference.contains("\0"),
            isValidFrameBookmarkIdentifier(sourceWindowID),
            frame?.isValid ?? true
        else {
            throw RestorationValidationError(issues: [.init(
                path: "bookmark",
                message: "A frame bookmark has an invalid context or source identity."
            )])
        }

        var updated = bookmarks
        let bookmark: WorkspaceFrameBookmark
        if let index = updated.firstIndex(where: {
            $0.contextReference == contextReference
        }) {
            updated[index].sourceWindowID = sourceWindowID
            if let frame {
                updated[index].frame = frame
            }
            bookmark = updated[index]
        } else {
            guard updated.count < Self.maximumBookmarks else {
                throw RestorationValidationError(issues: [.init(
                    path: "bookmarks",
                    message: "At most \(Self.maximumBookmarks) frame bookmarks can be saved."
                )])
            }
            bookmark = proposed
            updated.append(bookmark)
        }
        _ = try bookmark.validated()
        try persist(updated)
        return bookmark
    }

    /// Updates a bookmark's coordinates without changing which window is its
    /// active source. Passive same-context windows therefore cannot overwrite
    /// the frame that a user last activated.
    @discardableResult
    public func updateFrame(
        contextReference: String,
        sourceWindowID: String,
        frame: WorkspaceWindowFrame
    ) throws -> Bool {
        guard frame.isValid,
            let index = bookmarks.firstIndex(where: {
                $0.contextReference == contextReference
            }),
            bookmarks[index].sourceWindowID == sourceWindowID
        else { return false }
        guard bookmarks[index].frame != frame else { return true }
        var updated = bookmarks
        updated[index].frame = frame
        try persist(updated)
        return true
    }

    /// Creates a context bookmark when no history exists. If metadata exists
    /// without coordinates, automatic relaunch restoration may fill that
    /// missing frame without replacing the established source window.
    @discardableResult
    public func ensure(
        contextReference: String,
        sourceWindowID: String,
        frame: WorkspaceWindowFrame? = nil
    ) throws -> WorkspaceFrameBookmark {
        if let index = bookmarks.firstIndex(where: {
            $0.contextReference == contextReference
        }) {
            guard bookmarks[index].frame == nil, let frame else {
                return bookmarks[index]
            }
            guard frame.isValid else {
                throw RestorationValidationError(issues: [.init(
                    path: "frame",
                    message: "A frame bookmark must contain finite coordinates and positive bounded dimensions."
                )])
            }
            var updated = bookmarks
            updated[index].frame = frame
            try persist(updated)
            return updated[index]
        }
        return try activate(
            contextReference: contextReference,
            sourceWindowID: sourceWindowID,
            frame: frame
        )
    }

    public func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        bookmarks = []
        loadIssue = nil
    }

    private func persist(_ updated: [WorkspaceFrameBookmark]) throws {
        let document = Document(apiVersion: Self.apiVersion, bookmarks: updated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumDocumentBytes else {
            throw RestorationValidationError(issues: [.init(
                path: "bookmarks",
                message: "Saved frame bookmarks exceed the supported size."
            )])
        }
        defaults.set(data, forKey: Self.storageKey)
        bookmarks = updated
        loadIssue = nil
    }

    private func loadFromDefaults() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        guard data.count <= Self.maximumDocumentBytes else {
            resetAsInvalid(
                reason: .invalidData,
                message: "Saved frame bookmarks were too large and were reset."
            )
            return
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(DocumentHeader.self, from: data) else {
            resetAsInvalid(
                reason: .invalidData,
                message: "Saved frame bookmarks could not be decoded and were reset."
            )
            return
        }
        guard header.apiVersion == Self.apiVersion else {
            resetAsInvalid(
                reason: .unsupportedVersion,
                message: "Saved frame bookmarks use unsupported version \(header.apiVersion) and were reset."
            )
            return
        }
        guard let document = try? decoder.decode(Document.self, from: data) else {
            resetAsInvalid(
                reason: .invalidData,
                message: "Saved frame bookmarks could not be decoded and were reset."
            )
            return
        }
        do {
            guard document.bookmarks.count <= Self.maximumBookmarks,
                Set(document.bookmarks.map(\.id)).count == document.bookmarks.count,
                Set(document.bookmarks.map(\.contextReference)).count
                    == document.bookmarks.count
            else {
                throw RestorationValidationError(issues: [.init(
                    path: "bookmarks",
                    message: "Saved frame bookmarks exceed a limit or contain duplicates."
                )])
            }
            bookmarks = try document.bookmarks.map { try $0.validated() }
        } catch {
            resetAsInvalid(
                reason: .invalidValues,
                message: "Saved frame bookmarks contain invalid values and were reset."
            )
        }
    }

    private func resetAsInvalid(
        reason: WorkspaceFrameBookmarkLoadIssue.Reason,
        message: String
    ) {
        defaults.removeObject(forKey: Self.storageKey)
        bookmarks = []
        loadIssue = WorkspaceFrameBookmarkLoadIssue(reason: reason, message: message)
    }
}
