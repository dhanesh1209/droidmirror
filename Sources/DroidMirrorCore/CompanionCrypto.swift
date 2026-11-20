import Foundation
import CryptoKit

public enum CompanionRole: Sendable { case mac, phone }

public enum CompanionCryptoError: Error, Equatable {
    case invalidSecret, invalidSalt, frameTooLarge, malformedFrame, authenticationFailed, replayedOrOutOfOrder
}

/// One encrypted session between the Mac and the phone. See PLAN.md "Wire protocol (v1)".
/// A new channel (with fresh salts) is created for every connection, so frames from an
/// earlier session cannot be replayed into a new one.
public struct CompanionChannel {
    public static let secretLength = 32
    public static let saltLength = 16
    public static let nonceLength = 12
    public static let tagLength = 16
    public static let maxBodyLength = 1 << 20   // 1 MiB

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendSeq: UInt64 = 0
    private var lastReceivedSeq: UInt64 = 0

    public init(secret: Data, macSalt: Data, phoneSalt: Data, role: CompanionRole) throws {
        guard secret.count == Self.secretLength else { throw CompanionCryptoError.invalidSecret }
        guard macSalt.count == Self.saltLength, phoneSalt.count == Self.saltLength else { throw CompanionCryptoError.invalidSalt }
        let salt = macSalt + phoneSalt
        let macToPhone = Self.derive(secret: secret, label: "mac->phone", salt: salt)
        let phoneToMac = Self.derive(secret: secret, label: "phone->mac", salt: salt)
        switch role {
        case .mac:   sendKey = macToPhone; receiveKey = phoneToMac
        case .phone: sendKey = phoneToMac; receiveKey = macToPhone
        }
    }

    /// Per-direction, per-session key = HMAC-SHA256(secret, label || salt).
    static func derive(secret: Data, label: String, salt: Data) -> SymmetricKey {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + salt, using: SymmetricKey(data: secret))
        return SymmetricKey(data: Data(mac))
    }

    /// Encrypts one message and returns the full frame (4-byte length prefix + body).
    /// `nonce` is only for test vectors; production code must leave it nil (random).
    public mutating func seal(_ payload: Data, nonce: Data? = nil) throws -> Data {
        sendSeq += 1
        var plaintext = Data()
        for shift in stride(from: 56, through: 0, by: -8) { plaintext.append(UInt8((sendSeq >> UInt64(shift)) & 0xff)) }
        plaintext.append(payload)

        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: n)
        var body = Data()
        body.append(contentsOf: n)
        body.append(box.ciphertext)
        body.append(box.tag)
        guard body.count <= Self.maxBodyLength else { throw CompanionCryptoError.frameTooLarge }

        var frame = Data()
        let len = UInt32(body.count)
        for shift in stride(from: 24, through: 0, by: -8) { frame.append(UInt8((len >> UInt32(shift)) & 0xff)) }
        frame.append(body)
        return frame
    }

    /// Decrypts one frame body (without the length prefix). Rejects tampering, wrong session/direction and replays.
    public mutating func open(body rawBody: Data) throws -> Data {
        let body = Data(rawBody)
        guard body.count >= Self.nonceLength + 8 + Self.tagLength, body.count <= Self.maxBodyLength else {
            throw CompanionCryptoError.malformedFrame
        }
        let nonce = try AES.GCM.Nonce(data: body.prefix(Self.nonceLength))
        let tag = body.suffix(Self.tagLength)
        let ciphertext = body.dropFirst(Self.nonceLength).dropLast(Self.tagLength)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            plaintext = try AES.GCM.open(box, using: receiveKey)
        } catch {
            throw CompanionCryptoError.authenticationFailed
        }
        guard plaintext.count >= 8 else { throw CompanionCryptoError.malformedFrame }
        let seq = plaintext.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard seq > lastReceivedSeq else { throw CompanionCryptoError.replayedOrOutOfOrder }
        lastReceivedSeq = seq
        return Data(plaintext.dropFirst(8))
    }
}

/// Splits a TCP byte stream into frame bodies. After any thrown error the stream is
/// unusable and the connection must be closed.
public struct CompanionFrameDecoder {
    private var buffer = Data()
    public init() {}

    public mutating func feed(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var bodies: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = Int(buffer[start..<start + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length <= CompanionChannel.maxBodyLength else { throw CompanionCryptoError.frameTooLarge }
            guard buffer.count >= 4 + length else { break }
            bodies.append(Data(buffer[start + 4 ..< start + 4 + length]))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return bodies
    }
}
