import Foundation
import RedisClient
import Testing
@testable import Redi

/// Certificates and keys are stored as PEM text, so choosing a binary file shows the commands that
/// convert it. Those commands must be right: the user pastes them straight into Terminal.
@MainActor
struct CertificateHintTests {
    private typealias Editor = ConnectionEditor

    @Test func pkcs12ForTheClientCertificateOrKeyExportsBoth() {
        let expected = """
            cd '/Users/a/My Certs'
            /usr/bin/openssl pkcs12 -in id.p12 -clcerts -nokeys -out id-cert.pem
            /usr/bin/openssl pkcs12 -in id.p12 -nocerts -nodes -out id-key.pem
            """
        let file = URL(fileURLWithPath: "/Users/a/My Certs/id.p12")
        for target in [Editor.FileTarget.clientCertificate, .clientKey] {
            let problem = Editor.notPEMProblem(file: file, target: target)
            #expect(problem.commands == expected)
            #expect(problem.message.contains("PKCS#12"))
        }
        #expect(Editor.notPEMProblem(file: URL(fileURLWithPath: "/tmp/ID.PFX"), target: .clientKey).commands
            .contains("pkcs12 -in ID.PFX -nocerts -nodes -out ID-key.pem"))
    }

    @Test func pkcs12ForTheCAExportsItsCACertificates() {
        let problem = Editor.notPEMProblem(file: URL(fileURLWithPath: "/tmp/bundle.p12"), target: .caCertificate)
        #expect(problem.commands == "cd /tmp\n/usr/bin/openssl pkcs12 -in bundle.p12 -cacerts -nokeys -out bundle-ca.pem")
    }

    @Test func otherBinaryFilesAreTreatedAsDER() {
        #expect(Editor.notPEMProblem(file: URL(fileURLWithPath: "/tmp/ca.cer"), target: .caCertificate).commands
            == "cd /tmp\n/usr/bin/openssl x509 -inform der -in ca.cer -out ca.pem")
        #expect(Editor.notPEMProblem(file: URL(fileURLWithPath: "/tmp/client.der"), target: .clientCertificate).commands
            == "cd /tmp\n/usr/bin/openssl x509 -inform der -in client.der -out client.pem")
        #expect(Editor.notPEMProblem(file: URL(fileURLWithPath: "/tmp/client.key"), target: .clientKey).commands
            == "cd /tmp\n/usr/bin/openssl pkey -inform der -in client.key -out client.pem")
        // Never write over the file being converted.
        #expect(Editor.notPEMProblem(file: URL(fileURLWithPath: "/tmp/ca.pem"), target: .caCertificate).commands
            .hasSuffix("-in ca.pem -out ca-converted.pem"))
    }

    @Test func shellQuoting() {
        #expect(Editor.shellQuoted("plain-name_1.p12") == "plain-name_1.p12")
        #expect(Editor.shellQuoted("my id.p12") == "'my id.p12'")
        #expect(Editor.shellQuoted("it's.p12") == #"'it'\''s.p12'"#)
        #expect(Editor.shellQuoted("$HOME;rm") == "'$HOME;rm'")
        #expect(Editor.shellQuoted("") == "''")
    }

    /// Runs the suggested commands on the dev TLS fixture's `client.p12` (from `Scripts/gen-tls-certs.sh`),
    /// in a folder whose name needs quoting, and loads the results the way a saved connection does.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: CertificateHintTests.tlsFixture.appending(path: "client.p12").path)))
    func suggestedCommandsProduceUsableFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Redi hint's test \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let p12 = folder.appending(path: "my id.p12")
        try FileManager.default.copyItem(at: Self.tlsFixture.appending(path: "client.p12"), to: p12)

        // The fixture's password is given on the command line; a user is prompted for it instead.
        let export = Editor.notPEMProblem(file: p12, target: .clientCertificate).commands
            .split(separator: "\n").map { $0.hasPrefix("/usr/bin/openssl") ? $0 + " -passin pass:redi" : String($0) }
            .joined(separator: "\n")
        let (status, output) = try Self.shell(export)
        #expect(status == 0, "\(output)")
        let certificate = try String(contentsOf: folder.appending(path: "my id-cert.pem"), encoding: .utf8)
        let key = try String(contentsOf: folder.appending(path: "my id-key.pem"), encoding: .utf8)
        _ = try CertificateLoader.identity(certificatePEM: certificate, privateKeyPEM: key)

        let der = folder.appending(path: "ca file.cer")
        let ca = Self.tlsFixture.appending(path: "ca.crt").path
        #expect(try Self.shell("/usr/bin/openssl x509 -in \(Editor.shellQuoted(ca)) -outform der -out \(Editor.shellQuoted(der.path))").status == 0)
        #expect(try Self.shell(Editor.notPEMProblem(file: der, target: .caCertificate).commands).status == 0)
        let converted = try String(contentsOf: folder.appending(path: "ca file.pem"), encoding: .utf8)
        #expect(converted.hasPrefix("-----BEGIN CERTIFICATE-----"))
        #expect(try CertificateLoader.certificateDER(from: Data(converted.utf8)).count == 1)
    }

    nonisolated static let tlsFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: ".dev-redis/tls")

    /// `Process.waitUntilExit()` can hang under Swift concurrency, so this waits on the termination handler.
    private static func shell(_ script: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
