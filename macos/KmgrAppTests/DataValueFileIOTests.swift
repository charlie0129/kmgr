import Darwin
import Dispatch
import Foundation
import Testing
@testable import Kmgr

@Test("ConfigMap and Secret file imports enforce the opened-file Kubernetes byte limit")
func oversizedDataValueFileIsRejectedFromOpenedDescriptor() throws {
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

@Test("bounded data file I/O atomically round-trips binary bytes with private permissions")
func boundedDataValueFileRoundTripsBoundary() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-data-file-boundary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("value.bin")
    let expected = Data([0x00, 0xff, 0x10, 0x80, 0x00, 0x7f, 0xfe, 0x01,
                         0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
    try Data("replaced atomically".utf8).write(to: url)
    try DataValueFileIO.write(expected, to: url)

    #expect(try DataValueFileIO.readBounded(from: url, maximumByteCount: 16) == expected)
    var information = stat()
    let statResult = url.withUnsafeFileSystemRepresentation { path in
        path.map { Darwin.lstat($0, &information) } ?? -1
    }
    #expect(statResult == 0)
    #expect(information.st_mode & mode_t(0o777) == mode_t(0o600))
}

@Test("FIFO imports are rejected promptly without waiting for a writer")
func dataValueFIFOIsRejectedWithoutBlocking() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-data-file-fifo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("value.fifo")
    let makeResult = url.withUnsafeFileSystemRepresentation { path in
        path.map { Darwin.mkfifo($0, mode_t(0o600)) } ?? -1
    }
    #expect(makeResult == 0)

    // If a regression drops O_NONBLOCK, this delayed writer releases the
    // blocked open so the test fails by duration instead of hanging forever.
    let unblocker = Task.detached {
        try? await Task.sleep(for: .seconds(1))
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }
    defer { unblocker.cancel() }

    let clock = ContinuousClock()
    let started = clock.now
    #expect(throws: DataValueFileIO.ImportError.notRegularFile) {
        try DataValueFileIO.readBounded(from: url)
    }
    #expect(started.duration(to: clock.now) < .milliseconds(500))
}

@Test("regular-file symlink imports validate and read the opened target")
func dataValueSymlinkToRegularFileIsAccepted() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-data-file-symlink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target.bin")
    let link = directory.appendingPathComponent("selected.bin")
    let expected = Data([0x00, 0xff, 0x01, 0xfe])
    try expected.write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(try DataValueFileIO.readBounded(from: link) == expected)
}

@Test("cancelled atomic export removes its private temporary file")
func cancelledDataValueExportCleansUp() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("kmgr-data-file-cancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("secret.bin")
    let gate = DataValueWriteGate()
    let task = Task.detached {
        try DataValueFileIO.write(
            Data(repeating: 0xa5, count: 128 << 10),
            to: destination,
            beforeWritingChunk: { try gate.pause() }
        )
    }
    defer {
        gate.release()
        task.cancel()
    }

    try await waitForDataValueFileCondition { gate.started }
    let filesDuringWrite = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(filesDuringWrite.contains { $0.lastPathComponent.hasPrefix(".kmgr-export-") })

    task.cancel()
    gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
}

private final class DataValueWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var storedStarted = false

    var started: Bool { lock.withLock { storedStarted } }

    func pause() throws {
        lock.withLock { storedStarted = true }
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

private func waitForDataValueFileCondition(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw CancellationError() }
        try await Task.sleep(for: .milliseconds(5))
    }
}
