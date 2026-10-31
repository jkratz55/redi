import Foundation
import Security
import Synchronization

/// Kinds of secret attached to a connection profile.
public enum SecretKind: String, CaseIterable, Sendable {
    case password
    case sentinelPassword
    /// SSH password, or the passphrase of the SSH private key.
    case sshSecret
    /// PEM private key for TLS client authentication.
    case tlsClientKey
}

/// All secrets for one profile.
public struct ConnectionSecrets: Sendable, Hashable {
    public var password: String?
    public var sentinelPassword: String?
    public var sshSecret: String?
    public var tlsClientKey: String?

    public init(password: String? = nil, sentinelPassword: String? = nil, sshSecret: String? = nil, tlsClientKey: String? = nil) {
        self.password = password
        self.sentinelPassword = sentinelPassword
        self.sshSecret = sshSecret
        self.tlsClientKey = tlsClientKey
    }

    public subscript(kind: SecretKind) -> String? {
        get {
            switch kind {
            case .password: password
            case .sentinelPassword: sentinelPassword
            case .sshSecret: sshSecret
            case .tlsClientKey: tlsClientKey
            }
        }
        set {
            let value = newValue?.isEmpty == true ? nil : newValue
            switch kind {
            case .password: password = value
            case .sentinelPassword: sentinelPassword = value
            case .sshSecret: sshSecret = value
            case .tlsClientKey: tlsClientKey = value
            }
        }
    }
}

public protocol SecretStore: Sendable {
    func secrets(for profileID: UUID) throws -> ConnectionSecrets
    func setSecrets(_ secrets: ConnectionSecrets, for profileID: UUID) throws
    func deleteSecrets(for profileID: UUID) throws
}

public struct SecretStoreError: Error, Sendable, Hashable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Generic-password items in the login keychain, one per profile and secret kind.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.github.jkratz55.Redi") {
        self.service = service
    }

    public func secrets(for profileID: UUID) throws -> ConnectionSecrets {
        var secrets = ConnectionSecrets()
        for kind in SecretKind.allCases {
            secrets[kind] = try read(account: account(profileID, kind))
        }
        return secrets
    }

    public func setSecrets(_ secrets: ConnectionSecrets, for profileID: UUID) throws {
        for kind in SecretKind.allCases {
            let account = account(profileID, kind)
            if let value = secrets[kind] {
                try write(value, account: account)
            } else {
                try delete(account: account)
            }
        }
    }

    public func deleteSecrets(for profileID: UUID) throws {
        for kind in SecretKind.allCases { try delete(account: account(profileID, kind)) }
    }

    private func account(_ id: UUID, _ kind: SecretKind) -> String { "\(id.uuidString).\(kind.rawValue)" }

    private func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound: return nil
        default: throw SecretStoreError(status: status)
        }
    }

    private func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var item = baseQuery(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Redi connection secret"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
    }
}

/// Non-persistent store for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[UUID: ConnectionSecrets]>([:])

    public init() {}

    public func secrets(for profileID: UUID) throws -> ConnectionSecrets {
        storage.withLock { $0[profileID] ?? ConnectionSecrets() }
    }

    public func setSecrets(_ secrets: ConnectionSecrets, for profileID: UUID) throws {
        storage.withLock { $0[profileID] = secrets }
    }

    public func deleteSecrets(for profileID: UUID) throws {
        storage.withLock { _ = $0.removeValue(forKey: profileID) }
    }
}
