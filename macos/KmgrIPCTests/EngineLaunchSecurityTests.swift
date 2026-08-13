import Foundation
import GRPCCore
@testable import KmgrIPC
import Testing

@Suite("Engine launch security")
struct EngineLaunchSecurityTests {
    @Test("private endpoint is 0700 with a short contained socket")
    func privateEndpoint() throws {
        let endpoint = try EngineLaunchEndpoint.create()
        defer { try? endpoint.cleanup() }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: endpoint.directoryURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(endpoint.socketURL.deletingLastPathComponent() == endpoint.directoryURL)
        #expect(endpoint.socketURL.path.utf8.count <= EngineLaunchEndpoint.maximumSocketPathBytes)
    }

    @Test("cleanup removes only the owned launch directory")
    func cleanup() throws {
        let endpoint = try EngineLaunchEndpoint.create()
        let path = endpoint.directoryURL.path
        #expect(FileManager.default.fileExists(atPath: path))
        try endpoint.cleanup()
        #expect(!FileManager.default.fileExists(atPath: path))
        // Idempotent cleanup makes normal exit/restart races harmless.
        try endpoint.cleanup()
    }

    @Test("failed token generation removes the just-created directory")
    func failedTokenGenerationCleansUp() throws {
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("kt\(String(UUID().uuidString.prefix(6)))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(throws: SyntheticError.self) {
            try EngineLaunchEndpoint.create(
                baseDirectoryURL: base,
                tokenGenerator: { throw SyntheticError() }
            )
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: base.path)
        #expect(remaining.isEmpty)
    }

    @Test("launch token is 256 random bits encoded without printable diagnostics")
    func launchTokenShape() throws {
        let first = try EngineLaunchToken.random()
        let second = try EngineLaunchToken.random()
        #expect(first.value.count == 64)
        #expect(first.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(first != second)
        #expect(first.authorizationValue.hasPrefix("Bearer "))
    }

    @Test("authorization interceptor replaces duplicates with exactly one token")
    func authorizationInterceptor() async throws {
        let token = try EngineLaunchToken.random()
        let interceptor = BearerTokenInterceptor(
            authorizationValue: token.authorizationValue
        )
        var request = StreamingClientRequest<String>(metadata: [
            "authorization": "untrusted-one",
            "Authorization": "untrusted-two"
        ]) { _ in }
        request.metadata.addString("untrusted-three", forKey: "authorization")
        let descriptor = MethodDescriptor(
            service: ServiceDescriptor(fullyQualifiedService: "test.Security"),
            method: "Authenticate",
            type: .unary
        )
        let context = ClientContext(
            descriptor: descriptor,
            remotePeer: "unix:test",
            localPeer: "unix:test-client"
        )
        let response: StreamingClientResponse<String> = try await interceptor.intercept(
            request: request,
            context: context
        ) { forwarded, _ in
            let values = Array(forwarded.metadata[stringValues: "authorization"])
            #expect(values == [token.authorizationValue])
            return StreamingClientResponse(
                of: String.self,
                error: RPCError(code: .cancelled, message: "test complete")
            )
        }
        await #expect(throws: RPCError.self) {
            _ = try await response.messages.first { _ in true }
        }
    }
}

private struct SyntheticError: Error {}
