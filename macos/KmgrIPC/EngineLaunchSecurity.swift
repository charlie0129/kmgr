import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif

public enum EngineLaunchSecurityError: Error, LocalizedError, Sendable {
    case unsupportedPlatform
    case temporaryDirectoryCreation(Int32)
    case temporaryDirectoryPermissions(Int)
    case randomTokenGeneration(Int32)
    case socketPathTooLong(Int)
    case unsafeCleanupPath(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Private Unix-socket launch directories are unsupported on this platform."
        case .temporaryDirectoryCreation(let code):
            "Could not create the engine launch directory (errno \(code))."
        case .temporaryDirectoryPermissions(let permissions):
            "The engine launch directory has permissions \(String(permissions, radix: 8)); expected 700."
        case .randomTokenGeneration(let status):
            "Could not generate engine launch credentials (Security status \(status))."
        case .socketPathTooLong(let length):
            "The engine Unix-socket path is too long (\(length) bytes)."
        case .unsafeCleanupPath:
            "Refused to remove an unrecognized engine launch directory."
        }
    }
}

/// A random per-launch credential. Its value is intentionally internal and the
/// type has no printable conformance, preventing accidental interpolation into
/// diagnostics. It is used only for helper launch and authenticated metadata.
public struct EngineLaunchToken: Sendable, Equatable {
    static let byteCount = 32
    let value: String

    public static func random(
        bytes: (@Sendable (UnsafeMutableRawBufferPointer) -> Int32)? = nil
    ) throws -> Self {
        var random = [UInt8](repeating: 0, count: byteCount)
        let status = random.withUnsafeMutableBytes { buffer in
            if let bytes { return bytes(buffer) }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw EngineLaunchSecurityError.randomTokenGeneration(status)
        }
        return Self(value: random.map { String(format: "%02x", $0) }.joined())
    }

    var authorizationValue: String { "Bearer \(value)" }
}

/// Owns one short GUI-created launch directory. The engine creates and removes
/// the socket itself; the GUI removes only this validated directory after the
/// helper has exited.
public struct EngineLaunchEndpoint: Sendable, Equatable {
    public static let maximumSocketPathBytes = 103

    public let directoryURL: URL
    public let socketURL: URL
    let token: EngineLaunchToken
    private let baseDirectoryURL: URL

    public static func create(
        baseDirectoryURL: URL = URL(fileURLWithPath: "/tmp", isDirectory: true),
        tokenGenerator: @Sendable () throws -> EngineLaunchToken = {
            try EngineLaunchToken.random()
        }
    ) throws -> Self {
        #if canImport(Darwin)
        let base = baseDirectoryURL.standardizedFileURL.path
        var template = Array("\(base)/kmgr.XXXXXX".utf8CString)
        let created: UnsafeMutablePointer<CChar>? = template.withUnsafeMutableBufferPointer {
            guard let address = $0.baseAddress else { return nil }
            return mkdtemp(address)
        }
        guard created != nil else {
            throw EngineLaunchSecurityError.temporaryDirectoryCreation(errno)
        }
        let directoryPath = String(
            decoding: template.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
        let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryPath
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: directoryPath)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            guard permissions == 0o700 else {
                throw EngineLaunchSecurityError.temporaryDirectoryPermissions(permissions)
            }

            let socketURL = directoryURL.appendingPathComponent("e.sock", isDirectory: false)
            let socketBytes = socketURL.path.utf8.count
            guard socketBytes <= maximumSocketPathBytes else {
                throw EngineLaunchSecurityError.socketPathTooLong(socketBytes)
            }
            return try Self(
                directoryURL: directoryURL,
                socketURL: socketURL,
                token: try tokenGenerator(),
                baseDirectoryURL: baseDirectoryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
        #else
        throw EngineLaunchSecurityError.unsupportedPlatform
        #endif
    }

    init(
        directoryURL: URL,
        socketURL: URL,
        token: EngineLaunchToken,
        baseDirectoryURL: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)
    ) throws {
        self.directoryURL = directoryURL.standardizedFileURL
        self.socketURL = socketURL.standardizedFileURL
        self.token = token
        self.baseDirectoryURL = baseDirectoryURL.standardizedFileURL
        try validateCleanupTarget()
    }

    var helperArguments: [String] {
        [
            "--socket", socketURL.path,
            "--token", token.value,
            "--parent-liveness-stdin",
        ]
    }

    public func cleanup() throws {
        try validateCleanupTarget()
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    private func validateCleanupTarget() throws {
        let parent = directoryURL.deletingLastPathComponent().standardizedFileURL
        guard parent == baseDirectoryURL,
            directoryURL.lastPathComponent.hasPrefix("kmgr."),
            directoryURL.lastPathComponent.count > "kmgr.".count,
            socketURL.deletingLastPathComponent().standardizedFileURL == directoryURL,
            socketURL.lastPathComponent == "e.sock"
        else {
            throw EngineLaunchSecurityError.unsafeCleanupPath(directoryURL.path)
        }
    }
}
