import Foundation
import Testing
@testable import Kmgr

@Test("ConfigMap and Secret file imports enforce the Kubernetes byte limit before reading")
func oversizedDataValueFileIsRejectedFromMetadata() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-data-file-limit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("oversized-value.bin")
    #expect(FileManager.default.createFile(atPath: url.path, contents: Data()))
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(DataValueFileIO.maximumImportByteCount + 1))
    try handle.close()

    #expect(throws: DataValueFileIO.ImportError.exceedsKubernetesLimit(
        byteCount: DataValueFileIO.maximumImportByteCount + 1
    )) {
        try DataValueFileIO.readBounded(from: url)
    }
    let issue = DataValueFileIO.ImportError.exceedsKubernetesLimit(
        byteCount: DataValueFileIO.maximumImportByteCount + 1
    )
    #expect(DataValueFileIO.maximumImportByteCount == 1 << 20)
    #expect(issue.localizedDescription.contains("Kubernetes limits an entire ConfigMap or Secret"))
}

@Test("bounded data file I/O round-trips binary bytes at the exact configured boundary")
func boundedDataValueFileRoundTripsBoundary() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-data-file-boundary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("value.bin")
    let expected = Data([0x00, 0xff, 0x10, 0x80, 0x00, 0x7f, 0xfe, 0x01,
                         0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
    try DataValueFileIO.write(expected, to: url)

    #expect(try DataValueFileIO.readBounded(from: url, maximumByteCount: 16) == expected)
}

@Test("bounded data reads continue across short chunks and stop at limit plus one")
func boundedDataValueFileAccumulatesShortReads() throws {
    var chunks = [Data([0x00, 0x01]), Data([0x02]), Data([0x03]), Data()]
    let value = try DataValueFileIO.accumulateBounded(maximumByteCount: 4) { requested in
        #expect((1...5).contains(requested))
        return chunks.removeFirst()
    }
    #expect(value == Data([0x00, 0x01, 0x02, 0x03]))

    var oversizedChunks = [Data([0x00, 0x01]), Data([0x02, 0x03]), Data([0x04])]
    #expect(throws: DataValueFileIO.ImportError.exceedsKubernetesLimit(byteCount: nil)) {
        try DataValueFileIO.accumulateBounded(maximumByteCount: 4) { _ in
            oversizedChunks.removeFirst()
        }
    }
}
