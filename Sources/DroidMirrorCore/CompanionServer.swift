import Foundation
import Network

public enum CompanionServerError: Error { case startTimeout }

/// Listens for the phone on the local network. One authenticated phone at a time.
/// Handshake: the Mac sends a 16-byte salt, the phone answers with its own 16-byte salt,
/// then both sides use encrypted frames (see CompanionCrypto.swift). A connection only
/// counts once it sends a frame that decrypts correctly, so strangers cannot kick the phone off.
public final class CompanionServer: @unchecked Sendable {
    public var onEvent: (@Sendable (PhoneToMac) -> Void)?
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    fileprivate let queue = DispatchQueue(label: "droidmirror.companion")
    fileprivate let secret: Data
    private var listener: NWListener?
    private var pending: [ObjectIdentifier: Session] = [:]
    private var active: Session?
    private let maxPending = 8
    private let heartbeatInterval: TimeInterval
    private let idleTimeout: TimeInterval
    private var heartbeat: DispatchSourceTimer?

    /// The Mac pings the phone every `heartbeatInterval` seconds and drops a link that has been
    /// silent for `idleTimeout` seconds, so a half-open connection cannot linger unnoticed.
    public init(secret: Data, heartbeatInterval: TimeInterval = 15, idleTimeout: TimeInterval = 45) {
        self.secret = secret
        self.heartbeatInterval = heartbeatInterval
        self.idleTimeout = idleTimeout
    }

    /// Starts listening and returns the port. Tries `preferredPort` first (so a QR code stays valid),
    /// then any free port. Blocks briefly; do not call on the main thread.
    @discardableResult
    public func start(preferredPort: UInt16 = 0) throws -> UInt16 {
        do { return try startListener(on: preferredPort) }
        catch where preferredPort != 0 { return try startListener(on: 0) }
    }

    private func startListener(on port: UInt16) throws -> UInt16 {
        let l = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let e): failure = e; ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else { l.cancel(); throw CompanionServerError.startTimeout }
        if let failure { l.cancel(); throw failure }
        listener = l
        startHeartbeat()
        return l.port?.rawValue ?? 0
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        heartbeat = t
    }

    private func tick() {
        guard let s = active else { return }
        if Date().timeIntervalSince(s.lastReceived) > idleTimeout { s.close(); return }
        s.send(.ping)
    }

    public func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            active?.close()
            for s in pending.values { s.close() }
        }
    }

    /// True while an authenticated phone is connected. Call from outside the server's callbacks only.
    public var isConnected: Bool { queue.sync { active != nil } }

    public func send(_ message: MacToPhone) {
        queue.async { [weak self] in self?.active?.send(message) }
    }

    // MARK: - internals (all on `queue`)

    private func accept(_ connection: NWConnection) {
        guard pending.count < maxPending else { connection.cancel(); return }
        let s = Session(connection: connection, server: self)
        pending[ObjectIdentifier(s)] = s
        s.start()
    }

    fileprivate func promote(_ s: Session) {
        pending.removeValue(forKey: ObjectIdentifier(s))
        if let old = active, old !== s { old.close() }
        active = s
        onConnectionChange?(true)
    }

    fileprivate func ended(_ s: Session) {
        pending.removeValue(forKey: ObjectIdentifier(s))
        if active === s {
            active = nil
            onConnectionChange?(false)
        }
    }

    fileprivate func deliver(_ m: PhoneToMac) { onEvent?(m) }
}

private final class Session {
    private let conn: NWConnection
    private weak var server: CompanionServer?
    private var channel: CompanionChannel?
    private var decoder = CompanionFrameDecoder()
    private let macSalt: Data
    private var authenticated = false
    private var closed = false
    /// When the last valid frame arrived (used by the server's idle check).
    var lastReceived = Date()

    init(connection: NWConnection, server: CompanionServer) {
        self.conn = connection
        self.server = server
        var g = SystemRandomNumberGenerator()
        self.macSalt = Data((0..<CompanionChannel.saltLength).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    func start() {
        guard let server else { return }
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.server?.ended(self!)
            default: break
            }
        }
        conn.start(queue: server.queue)
        server.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.authenticated == false { self?.close() }
        }
        conn.send(content: macSalt, completion: .contentProcessed { [weak self] e in if e != nil { self?.close() } })
        conn.receive(minimumIncompleteLength: CompanionChannel.saltLength, maximumLength: CompanionChannel.saltLength) { [weak self] data, _, _, error in
            guard let self, let server = self.server, let data, data.count == CompanionChannel.saltLength, error == nil else { self?.close(); return }
            do {
                self.channel = try CompanionChannel(secret: server.secret, macSalt: self.macSalt, phoneSalt: data, role: .mac)
            } catch { self.close(); return }
            self.receiveLoop()
        }
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for body in try self.decoder.feed(data) {
                        let payload = try self.channel!.open(body: body)
                        self.lastReceived = Date()
                        guard let message = try? PhoneToMac.decode(payload) else { self.close(); return }
                        if !self.authenticated {
                            self.authenticated = true
                            self.server?.promote(self)
                        }
                        self.server?.deliver(message)
                    }
                } catch { self.close(); return }
            }
            if error != nil || isComplete { self.close(); return }
            self.receiveLoop()
        }
    }

    func send(_ message: MacToPhone) {
        guard channel != nil, let payload = try? message.encode(), let frame = try? channel!.seal(payload) else { return }
        conn.send(content: frame, completion: .contentProcessed { [weak self] e in if e != nil { self?.close() } })
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
    }
}
