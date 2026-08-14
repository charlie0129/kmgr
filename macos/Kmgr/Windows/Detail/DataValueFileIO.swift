import Foundation

/// Bounded file I/O for decoded ConfigMap and Secret values. Kubernetes caps
/// the complete data payload of either object at 1 MiB, so accepting a larger
/// value can only consume memory locally before the API server rejects it.
enum DataValueFileIO {
    static let maximumImportByteCount = 1 << 20

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

    /// Checks filesystem metadata before allocating a payload, then caps the
    /// actual read at limit + 1 to defend against a file that grows after the
    /// metadata check or a filesystem that did not report a useful size.
    static func readBounded(
        from url: URL,
        maximumByteCount: Int = maximumImportByteCount
    ) throws -> Data {
        precondition(maximumByteCount > 0 && maximumByteCount < Int.max)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportError.notRegularFile }
        if let fileSize = values.fileSize, fileSize > maximumByteCount {
            throw ImportError.exceedsKubernetesLimit(byteCount: fileSize)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try accumulateBounded(maximumByteCount: maximumByteCount) { chunkSize in
            try handle.read(upToCount: chunkSize)
        }
    }

    /// FileHandle may return a short chunk before EOF. Keep requesting bytes
    /// until EOF while ensuring the accumulator can never grow past limit + 1.
    static func accumulateBounded(
        maximumByteCount: Int,
        readChunk: (Int) throws -> Data?
    ) throws -> Data {
        precondition(maximumByteCount > 0 && maximumByteCount < Int.max)
        var value = Data()
        while value.count <= maximumByteCount {
            let remaining = maximumByteCount + 1 - value.count
            guard let chunk = try readChunk(min(64 << 10, remaining)),
                !chunk.isEmpty
            else { break }
            value.append(contentsOf: chunk.prefix(remaining))
        }
        guard value.count <= maximumByteCount else {
            throw ImportError.exceedsKubernetesLimit(byteCount: nil)
        }
        return value
    }

    static func write(_ value: Data, to url: URL) throws {
        try value.write(to: url, options: .atomic)
    }
}
