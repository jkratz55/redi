import Foundation
import Observation
import RediCore

/// Saved connection profiles, shared by every window. Profiles persist to Application Support;
/// secrets go to the Keychain (or memory, when UI tests pass `REDI_IN_MEMORY_SECRETS=1`).
@Observable
final class ConnectionStore {
    private(set) var profiles: [ConnectionProfile] = []
    /// The most recent persistence error, surfaced in the Connections window.
    var lastError: String?

    @ObservationIgnored private let repository: ProfileRepository
    @ObservationIgnored private let secretStore: any SecretStore

    init(repository: ProfileRepository = ProfileRepository(), secretStore: (any SecretStore)? = nil) {
        self.repository = repository
        if let secretStore {
            self.secretStore = secretStore
        } else if ProcessInfo.processInfo.environment["REDI_IN_MEMORY_SECRETS"] == "1" {
            self.secretStore = InMemorySecretStore()
        } else {
            self.secretStore = KeychainSecretStore()
        }
        do {
            profiles = try repository.load()
        } catch {
            lastError = "Couldn't load saved connections: \(error.localizedDescription)"
        }
    }

    /// Profiles sorted for display: most recently used first, then by name.
    var sortedProfiles: [ConnectionProfile] {
        profiles.sorted { lhs, rhs in
            switch (lhs.lastConnectedAt, rhs.lastConnectedAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    func profile(id: ConnectionProfile.ID?) -> ConnectionProfile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func secrets(for id: ConnectionProfile.ID) -> ConnectionSecrets {
        do {
            return try secretStore.secrets(for: id)
        } catch {
            lastError = "Couldn't read the Keychain: \(error)"
            return ConnectionSecrets()
        }
    }

    func save(_ profile: ConnectionProfile, secrets: ConnectionSecrets) {
        do {
            try secretStore.setSecrets(secrets, for: profile.id)
        } catch {
            lastError = "Couldn't save secrets to the Keychain: \(error)"
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    @discardableResult
    func duplicate(id: ConnectionProfile.ID) -> ConnectionProfile? {
        guard var copy = profile(id: id) else { return nil }
        let secrets = secrets(for: id)
        copy.id = UUID()
        copy.name = String(localized: "\(copy.displayName) Copy")
        copy.createdAt = Date()
        copy.lastConnectedAt = nil
        save(copy, secrets: secrets)
        return copy
    }

    func delete(ids: Set<ConnectionProfile.ID>) {
        for id in ids { try? secretStore.deleteSecrets(for: id) }
        profiles.removeAll { ids.contains($0.id) }
        persist()
    }

    func markConnected(id: ConnectionProfile.ID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].lastConnectedAt = Date()
        persist()
    }

    /// Imports a Redis Insight export. Returns the number of connections added.
    func importRedisInsight(from url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let imported = try RedisInsightImport.parse(Data(contentsOf: url))
        for var item in imported {
            if let key = item.sshPrivateKey {
                item.profile.ssh.privateKeyPath = try RedisInsightImport.storePrivateKey(key, for: item.profile.id)
            }
            save(item.profile, secrets: item.secrets)
        }
        return imported.count
    }

    private func persist() {
        do {
            try repository.save(profiles)
        } catch {
            lastError = "Couldn't save connections: \(error.localizedDescription)"
        }
    }
}
