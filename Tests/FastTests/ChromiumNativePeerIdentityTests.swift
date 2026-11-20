import Foundation
import Darwin
import CryptoKit
import Testing
@testable import YabCoreClient

/// Controlled identity/argv boundary tests, not a native peer/SDK proof.
struct ChromiumNativePeerIdentityTests {
    private func sample() -> NativePeerIdentity.Sample {
        .init(pid: 123, parent: 122, uid: getuid(), startSec: 1000, startUsec: 1,
              executable: "/owned/Task.app/Contents/MacOS/PaneCore", argvSHA256: String(repeating: "a", count: 64),
              bootSession: "01234567-89AB-4CDE-8123-456789ABCDEF", codeIdentifier: "owned.helper", codeUnique: String(repeating: "b", count: 40),
              audit: Data(repeating: 7, count: MemoryLayout<audit_token_t>.size))
    }
    private func expected(_ source: NativePeerIdentity.Sample) throws -> NativePeerIdentity.ExpectedImage {
        try #require(.init(executable: source.executable, identifier: source.codeIdentifier, unique: source.codeUnique, argumentsSHA256: source.argvSHA256))
    }
    @Test func exactControlledPeerProducesDiagnosticEvidenceOnly() throws {
        let source = sample(), image = try expected(source)
        let result = try #require(NativePeerIdentity.matched(source, source, expected: image))
        #expect(result.pid == source.pid && result.startSec == source.startSec && result.startUsec == source.startUsec)
        #expect(result.argvSHA256 == source.argvSHA256 && result.codeUnique == source.codeUnique)
        #expect(result.auditSHA256.count == 64)
        let restored = try JSONDecoder().decode(NativePeerIdentity.Evidence.self, from: JSONEncoder().encode(result))
        #expect(restored == result) // Evidence has no native owner/recovery API.
    }
    @Test func anyBirthParentUIDAuditCodeArgumentOrBootDriftRefuses() throws {
        let first = sample(), image = try expected(first)
        let changes: [(inout NativePeerIdentity.Sample) -> Void] = [
            { $0.pid += 1 }, { $0.parent += 1 }, { $0.uid = getuid() &+ 1 }, { $0.startSec += 1 }, { $0.startUsec += 1 },
            { $0.audit[0] ^= 1 }, { $0.executable += ".other" }, { $0.argvSHA256 = String(repeating: "c", count: 64) },
            { $0.codeIdentifier += ".other" }, { $0.codeUnique = String(repeating: "c", count: 40) },
            { $0.bootSession = "11234567-89AB-4CDE-8123-456789ABCDEF" }
        ]
        for change in changes {
            var last = first; change(&last)
            #expect(NativePeerIdentity.matched(first, last, expected: image) == nil)
        }
    }
    @Test func samePIDAndBirthCannotBlessAnotherExecutableRoleOrCode() throws {
        let first = sample(), image = try expected(first)
        var other = first; other.argvSHA256 = String(repeating: "c", count: 64)
        #expect(NativePeerIdentity.matched(other, other, expected: image) == nil)
        other = first; other.executable += ".other"
        #expect(NativePeerIdentity.matched(other, other, expected: image) == nil)
        other = first; other.codeUnique = String(repeating: "c", count: 40)
        #expect(NativePeerIdentity.matched(other, other, expected: image) == nil)
    }
    private func kernelArguments(_ arguments: [Data]) -> Data {
        var count = Int32(arguments.count), bytes = withUnsafeBytes(of: &count) { Data($0) }
        bytes.append(contentsOf: "/fixture/ceftests".utf8); bytes.append(contentsOf: [0, 0, 0])
        for argument in arguments { bytes.append(argument); bytes.append(0) }
        return bytes
    }
    @Test func kernelArgvParserKeepsEmptyArgumentsAndIgnoresEnvironment() throws {
        let argv = [Data("/fixture/ceftests".utf8), Data(), Data("--owned-fixture".utf8)]
        var canonical = Data(); for value in argv { canonical.append(value); canonical.append(0) }
        let expected = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let bytes = kernelArguments(argv)
        #expect(NativePeerIdentity.argumentsDigest(bytes) == expected)
        var withEnvironment = bytes; withEnvironment.append(contentsOf: "ENV_NOT_JOURNALED=value\0".utf8)
        #expect(NativePeerIdentity.argumentsDigest(withEnvironment) == expected)
        #expect(NativePeerIdentity.argumentsDigest(Data(bytes.dropLast())) == nil)
        #expect(NativePeerIdentity.argumentsDigest(Data()) == nil)
        #expect(NativePeerIdentity.argumentsDigest(Data(repeating: 0, count: 1024 * 1024 + 1)) == nil)
    }
    @Test func invalidCodePolicyAuditOrBirthNeverBecomesEvidence() throws {
        let first = sample(), image = try expected(first)
        var invalid = first; invalid.audit.removeAll()
        #expect(NativePeerIdentity.matched(invalid, invalid, expected: image) == nil)
        invalid = first; invalid.startSec = 0
        #expect(NativePeerIdentity.matched(invalid, invalid, expected: image) == nil)
        invalid = first; invalid.startUsec = 1_000_000
        #expect(NativePeerIdentity.matched(invalid, invalid, expected: image) == nil)
        #expect(NativePeerIdentity.ExpectedImage(executable: "relative", identifier: "helper", unique: image.unique, argumentsSHA256: first.argvSHA256) == nil)
        #expect(NativePeerIdentity.ExpectedImage(executable: first.executable, identifier: "helper", unique: "0", argumentsSHA256: first.argvSHA256) == nil)
    }
}
