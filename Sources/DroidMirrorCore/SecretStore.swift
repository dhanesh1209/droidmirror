import Foundation
import Security

public protocol SecretStore {
    func load() -> Data?
    func save(_ secret: Data) throws
}

public enum PairingSecret {
    /// 32 random bytes from the system CSPRNG.
    public static func generate() -> Data {
        var bytes = [UInt8](repeating: 0, count: CompanionChannel.secretLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "system random failed")
        return Data(bytes)
    }

    /// Loads the stored secret, or creates and saves one.
    public static func loadOrCreate(in store: SecretStore) throws -> Data {
        if let s = store.load() { return s }
        let s = generate()
        try store.save(s)
        return s
    }
}

/// Stores the secret in a user-only file (0600) under Application Support.
/// Keychain is the better home once the app is a signed bundle; an unsigned, repeatedly rebuilt
/// command-line app would trigger Keychain permission prompts on every build.
public struct FileSecretStore: SecretStore {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMirror/pairing.key")
    }

    public func load() -> Data? {
        guard let d = try? Data(contentsOf: url), d.count == CompanionChannel.secretLength else { return nil }
        return d
    }

    public func save(_ secret: Data) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try secret.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var secret: Data?
    public init(_ secret: Data? = nil) { self.secret = secret }
    public func load() -> Data? { secret }
    public func save(_ secret: Data) throws { self.secret = secret }
}
