import Foundation

/// Loads and saves connection profiles as JSON, written atomically.
public struct ProfileRepository: Sendable {
    public let fileURL: URL

    /// `~/Library/Application Support/Redi/connections.json`.
    public static var defaultFileURL: URL {
        RediDirectories.applicationSupport.appending(path: "connections.json")
    }

    public init(fileURL: URL = ProfileRepository.defaultFileURL) {
        self.fileURL = fileURL
    }

    private struct Document: Codable {
        var version = 1
        var profiles: [ConnectionProfile]
    }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.redi.decode(Document.self, from: data).profiles
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.redi.encode(Document(profiles: profiles))
        try data.write(to: fileURL, options: [.atomic])
    }
}

/// Redi's on-disk locations.
public enum RediDirectories {
    /// Honors `REDI_DATA_DIR` so UI tests never touch the user's real profiles.
    public static var applicationSupport: URL {
        if let override = ProcessInfo.processInfo.environment["REDI_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "Redi", directoryHint: .isDirectory)
    }

    /// Per-connection data (CLI history, Workbench results, analysis reports).
    public static func connectionData(_ profileID: UUID) -> URL {
        applicationSupport.appending(path: "Connections/\(profileID.uuidString)", directoryHint: .isDirectory)
    }
}

extension JSONEncoder {
    static var redi: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }
}

extension JSONDecoder {
    static var redi: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
