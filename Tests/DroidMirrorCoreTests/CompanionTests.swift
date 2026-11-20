import XCTest
@testable import DroidMirrorCore

final class CompanionTests: XCTestCase {
    // MARK: helpers

    private func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }
    private func hexString(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    private struct Frame { let label: String; let payload: String; let nonce: Data; let frame: Data }
    private struct Vectors { let secret: Data; let macSalt: Data; let phoneSalt: Data; let keys: [String: String]; let frames: [Frame] }

    private func loadVectors() throws -> Vectors {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/test-vectors.json"))
        let j = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let frames = (j["frames"] as! [[String: Any]]).map {
            Frame(label: $0["label"] as! String, payload: $0["payload"] as! String, nonce: hex($0["nonce"] as! String), frame: hex($0["frame"] as! String))
        }
        return Vectors(secret: hex(j["secret"] as! String), macSalt: hex(j["macSalt"] as! String), phoneSalt: hex(j["phoneSalt"] as! String),
                       keys: j["keys"] as! [String: String], frames: frames)
    }

    private func pair() throws -> (mac: CompanionChannel, phone: CompanionChannel) {
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let ms = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let ps = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        return (try CompanionChannel(secret: secret, macSalt: ms, phoneSalt: ps, role: .mac),
                try CompanionChannel(secret: secret, macSalt: ms, phoneSalt: ps, role: .phone))
    }

    private func body(of frame: Data) throws -> Data {
        var d = CompanionFrameDecoder()
        let bodies = try d.feed(frame)
        XCTAssertEqual(bodies.count, 1)
        return bodies[0]
    }

    // MARK: interop with Node-generated vectors

    func testKeyDerivationMatchesNode() throws {
        let v = try loadVectors()
        let salt = v.macSalt + v.phoneSalt
        for label in ["mac->phone", "phone->mac"] {
            let key = CompanionChannel.derive(secret: v.secret, label: label, salt: salt)
            XCTAssertEqual(hexString(key.withUnsafeBytes { Data($0) }), v.keys[label])
        }
    }

    func testSealMatchesNodeByteForByte() throws {
        let v = try loadVectors()
        var mac = try CompanionChannel(secret: v.secret, macSalt: v.macSalt, phoneSalt: v.phoneSalt, role: .mac)
        var phone = try CompanionChannel(secret: v.secret, macSalt: v.macSalt, phoneSalt: v.phoneSalt, role: .phone)
        for f in v.frames {
            let sealed = f.label == "mac->phone"
                ? try mac.seal(Data(f.payload.utf8), nonce: f.nonce)
                : try phone.seal(Data(f.payload.utf8), nonce: f.nonce)
            XCTAssertEqual(hexString(sealed), hexString(f.frame), "frame \(f.payload)")
        }
    }

    func testOpensNodeFrames() throws {
        let v = try loadVectors()
        var mac = try CompanionChannel(secret: v.secret, macSalt: v.macSalt, phoneSalt: v.phoneSalt, role: .mac)
        var phone = try CompanionChannel(secret: v.secret, macSalt: v.macSalt, phoneSalt: v.phoneSalt, role: .phone)
        for f in v.frames {
            let b = try body(of: f.frame)
            let opened = f.label == "mac->phone" ? try phone.open(body: b) : try mac.open(body: b)
            XCTAssertEqual(String(decoding: opened, as: UTF8.self), f.payload)
        }
    }

    // MARK: behaviour

    func testRoundTripBothDirections() throws {
        var (mac, phone) = try pair()
        let a = try mac.seal(Data("hello phone".utf8))
        XCTAssertEqual(String(decoding: try phone.open(body: try body(of: a)), as: UTF8.self), "hello phone")
        let b = try phone.seal(Data("hello mac".utf8))
        XCTAssertEqual(String(decoding: try mac.open(body: try body(of: b)), as: UTF8.self), "hello mac")
    }

    func testRejectsReplay() throws {
        var (mac, phone) = try pair()
        let b = try body(of: try mac.seal(Data("once".utf8)))
        _ = try phone.open(body: b)
        XCTAssertThrowsError(try phone.open(body: b)) { XCTAssertEqual($0 as? CompanionCryptoError, .replayedOrOutOfOrder) }
    }

    func testRejectsOutOfOrder() throws {
        var (mac, phone) = try pair()
        let first = try body(of: try mac.seal(Data("1".utf8)))
        let second = try body(of: try mac.seal(Data("2".utf8)))
        _ = try phone.open(body: second)
        XCTAssertThrowsError(try phone.open(body: first)) { XCTAssertEqual($0 as? CompanionCryptoError, .replayedOrOutOfOrder) }
    }

    func testRejectsTampering() throws {
        var (mac, phone) = try pair()
        var b = try body(of: try mac.seal(Data("secret".utf8)))
        b[b.startIndex + 14] ^= 0x01
        XCTAssertThrowsError(try phone.open(body: b)) { XCTAssertEqual($0 as? CompanionCryptoError, .authenticationFailed) }
    }

    func testRejectsFrameFromAnotherSession() throws {
        let secret = Data((0..<32).map { _ in UInt8(7) })
        let ps = Data(repeating: 2, count: 16)
        var macOld = try CompanionChannel(secret: secret, macSalt: Data(repeating: 1, count: 16), phoneSalt: ps, role: .mac)
        var phoneNew = try CompanionChannel(secret: secret, macSalt: Data(repeating: 9, count: 16), phoneSalt: ps, role: .phone)
        let b = try body(of: try macOld.seal(Data("old session".utf8)))
        XCTAssertThrowsError(try phoneNew.open(body: b)) { XCTAssertEqual($0 as? CompanionCryptoError, .authenticationFailed) }
    }

    func testRejectsReflectedFrame() throws {
        var (mac, _) = try pair()
        var (mac2, _) = try pair()
        // A frame the Mac sealed must never open on a Mac channel (direction keys differ).
        let b = try body(of: try mac.seal(Data("reflect".utf8)))
        XCTAssertThrowsError(try mac2.open(body: b))
    }

    func testRejectsBadInputs() {
        XCTAssertThrowsError(try CompanionChannel(secret: Data(count: 31), macSalt: Data(count: 16), phoneSalt: Data(count: 16), role: .mac)) {
            XCTAssertEqual($0 as? CompanionCryptoError, .invalidSecret)
        }
        XCTAssertThrowsError(try CompanionChannel(secret: Data(count: 32), macSalt: Data(count: 15), phoneSalt: Data(count: 16), role: .mac)) {
            XCTAssertEqual($0 as? CompanionCryptoError, .invalidSalt)
        }
    }

    func testDecoderHandlesPartialAndMultipleFrames() throws {
        var (mac, _) = try pair()
        let f1 = try mac.seal(Data("one".utf8)), f2 = try mac.seal(Data("two".utf8))
        let stream = f1 + f2
        var d = CompanionFrameDecoder()
        var got: [Data] = []
        for byte in stream { got += try d.feed(Data([byte])) }          // one byte at a time
        XCTAssertEqual(got.count, 2)
        var d2 = CompanionFrameDecoder()
        XCTAssertEqual(try d2.feed(stream).count, 2)                    // both at once
    }

    func testDecoderRejectsOversizeFrame() {
        var d = CompanionFrameDecoder()
        XCTAssertThrowsError(try d.feed(Data([0x00, 0x20, 0x00, 0x00]))) { XCTAssertEqual($0 as? CompanionCryptoError, .frameTooLarge) }
    }
}
