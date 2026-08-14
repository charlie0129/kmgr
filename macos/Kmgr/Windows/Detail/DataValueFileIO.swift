import Darwin
import Foundation

/// Bounded file I/O for decoded ConfigMap and Secret values. Kubernetes caps
/// the complete data payload of either object at 1 MiB, so accepting a larger
/// value can only consume memory locally before the API server rejects it.
enum DataValueFileIO {
    static let maximumImportByteCount = 1 << 20
    private static let chunkByteCount = 64 << 10

    enum ImportError: LocalizedError, Equatable {
        case notRegularFile
        case exceedsKubernetesLimit(byteCount: Int?)

        var errorDescription: String? {
            switch self {
            case .notRegularFile:
                return "Select a regular file to import."
            case .exceedsKubernetesLimit(let byteCount):
                let limit = maximumImportByteCount.formatted()
                if let byteCount {
                    return "The selected file is \(byteCount.formatted()) bytes. Kubernetes limits an entire ConfigMap or Secret to \(limit) bytes, so this value cannot be imported."
                }
                return "The selected file is larger than \(limit) bytes. Kubernetes limits an entire ConfigMap or Secret to \(limit) bytes, so this value cannot be imported."
            }
        }
    }

    /// Opens once with nonblocking semantics and validates that exact opened
    /// descriptor. A path swapped to a FIFO, device, or directory can neither
    /// block the UI worker nor pass a metadata check performed on a different
    /// filesystem object. Symlinks remain useful when their opened target is a
    /// regular file.
    static func readBounded(
        from url: URL,
        maximumByteCount: Int = maximumImportByteCount
    ) throws -> Data {
        precondition(maximumByteCount > 0 && maximumByteCount < Int.max)
        try Task.checkCancellation()
        guard url.isFileURL else { throw ImportError.notRegularFile }

        let descriptor = try openDescriptor(
            at: url,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC
        )
        defer { _ = Darwin.close(descriptor) }
        try Task.checkCancellation()

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw currentPOSIXError()
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw ImportError.notRegularFile
        }
        guard information.st_size >= 0 else { throw POSIXError(.EIO) }
        if information.st_size > off_t(maximumByteCount) {
            let byteCount = information.st_size <= off_t(Int.max)
                ? Int(information.st_size)
                : nil
            throw ImportError.exceedsKubernetesLimit(byteCount: byteCount)
        }

        var value = Data()
        var buffer = [UInt8](
            repeating: 0,
            count: min(chunkByteCount, maximumByteCount + 1)
        )
        while value.count <= maximumByteCount {
            try Task.checkCancellation()
            let requested = min(buffer.count, maximumByteCount + 1 - value.count)
            let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if readCount > 0 {
                buffer.withUnsafeBufferPointer { bytes in
                    value.append(bytes.baseAddress!, count: readCount)
                }
                continue
            }
            if readCount == 0 { break }
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
        guard value.count <= maximumByteCount else {
            throw ImportError.exceedsKubernetesLimit(byteCount: nil)
        }
        try Task.checkCancellation()
        return value
    }

    /// Writes through a private same-directory file and atomically renames it
    /// over the destination only after every bounded chunk is complete. The
    /// temporary file is removed on cancellation or any failure.
    static func write(
        _ value: Data,
        to url: URL,
        beforeWritingChunk: @escaping @Sendable () throws -> Void = {}
    ) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw POSIXError(.EINVAL) }
        let destinationName = url.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != "..",
            !destinationName.utf8.contains(0)
        else {
            throw POSIXError(.EINVAL)
        }

        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = try openDescriptor(
            at: directoryURL,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_DIRECTORY
        )
        defer { _ = Darwin.close(directoryDescriptor) }
        try Task.checkCancellation()

        let temporaryName = ".kmgr-export-\(UUID().uuidString).tmp"
        let descriptor = try openDescriptor(
            relativePath: temporaryName,
            directoryDescriptor: directoryDescriptor,
            flags: O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_CREAT | O_EXCL | O_NOFOLLOW,
            permissions: mode_t(S_IRUSR | S_IWUSR)
        )
        var removeTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if removeTemporaryFile {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw currentPOSIXError()
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw currentPOSIXError()
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw POSIXError(.EIO)
        }

        try value.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                try beforeWritingChunk()
                try Task.checkCancellation()
                let requested = min(chunkByteCount, bytes.count - offset)
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    requested
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw currentPOSIXError()
            }
        }
        try Task.checkCancellation()
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR {
                try Task.checkCancellation()
                continue
            }
            throw currentPOSIXError()
        }
        try Task.checkCancellation()

        let renameResult = temporaryName.withCString { temporaryPath in
            destinationName.withCString { destinationPath in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPath,
                    directoryDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else { throw currentPOSIXError() }
        removeTemporaryFile = false
    }

    private static func openDescriptor(
        at url: URL,
        flags: Int32,
        permissions: mode_t = 0
    ) throws -> Int32 {
        var invalidPath = false
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                invalidPath = true
                return -1
            }
            return Darwin.open(path, flags, permissions)
        }
        guard descriptor >= 0 else {
            if invalidPath { throw POSIXError(.EINVAL) }
            throw currentPOSIXError()
        }
        return descriptor
    }

    private static func openDescriptor(
        relativePath: String,
        directoryDescriptor: Int32,
        flags: Int32,
        permissions: mode_t
    ) throws -> Int32 {
        let descriptor = relativePath.withCString {
            Darwin.openat(directoryDescriptor, $0, flags, permissions)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        return descriptor
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
