import Foundation
import AppKit
import DroidMirrorCore

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var mirroringSerial: String?
    @Published var missingTools: [String] = []
    @Published var errorMessage: String?
    @Published var screenOff = true
    @Published var forwardNotifications = true
    @Published var wifiStatus: String?
    @Published var mdnsServices: [MdnsService] = []
    @Published var recentEndpoints: [String] = UserDefaults.standard.stringArray(forKey: "recentEndpoints") ?? []

    private var process: Process?
    private var deduppers: [String: NotificationDeduper] = [:]
    private var polling = false
    private var timer: Timer?

    // Companion link (no USB debugging needed)
    static let preferredCompanionPort: UInt16 = 47891
    @Published var companionConnected = false
    @Published var companionPhoneName: String?
    @Published var companionError: String?
    @Published private(set) var companionPort: UInt16?
    @Published private(set) var recentNotifications: [CompanionNotification] = []
    @Published var replyTarget: CompanionNotification?

    // Consent switches for local tools (the MCP bridge). Both are off by default and only the user can turn them on.
    @Published var toolsMayRead: Bool = UserDefaults.standard.bool(forKey: "toolsMayRead") {
        didSet { UserDefaults.standard.set(toolsMayRead, forKey: "toolsMayRead") }
    }
    @Published var toolsMayAct: Bool = UserDefaults.standard.bool(forKey: "toolsMayAct") {
        didSet { UserDefaults.standard.set(toolsMayAct, forKey: "toolsMayAct") }
    }
    private let currentServer = Locked<CompanionServer?>(nil)
    private let currentPhone = Locked<String?>(nil)
    private var controlServer: ControlServer?
    let notificationStore = NotificationStore()
    private var companion: CompanionServer?
    private var postedSignatures: [String: String] = [:]
    private var lastMissingTools: [String]?

    init() {
        Notifier.requestAuthorization()
        startControl()
        startCompanion()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if let p = process, !p.isRunning {
            process = nil
            mirroringSerial = nil
        }
        Task {
            let result = await Task.detached { () -> ([String], [AndroidDevice]?) in
                let missing = ToolCheck.missingRequiredTools()
                guard !missing.contains("adb") else { return (missing, nil) }
                return (missing, try? ADB.listDevices())
            }.value
            if lastMissingTools != result.0 {
                lastMissingTools = result.0
                log("tools missing: \(result.0.isEmpty ? "none" : result.0.joined(separator: ", "))")
            }
            missingTools = result.0
            if let d = result.1 { devices = d }
            pollNotifications()
        }
    }

    /// Reads notifications from each ready device and posts new ones on the Mac.
    /// The first poll per device is a baseline, so existing notifications are not replayed.
    private func pollNotifications() {
        // The companion link is the primary source; only fall back to adb polling when it is not connected.
        guard forwardNotifications, !companionConnected, !polling else { return }
        let serials = devices.filter(\.isReady).map(\.serial)
        guard !serials.isEmpty else { return }
        polling = true
        var states = deduppers
        Task {
            let outcome = await Task.detached { () -> ([String: NotificationDeduper], [PhoneNotification]) in
                var fresh: [PhoneNotification] = []
                let filter = NotificationFilter()
                for serial in serials {
                    guard let list = try? ADB.fetchNotifications(serial: serial) else { continue }
                    var d = states[serial] ?? NotificationDeduper()
                    fresh += d.fresh(list.filter(filter.shouldForward))
                    states[serial] = d
                }
                return (states, fresh)
            }.value
            deduppers = outcome.0
            for n in outcome.1 { Notifier.post(n) }
            polling = false
        }
    }

    // MARK: - Companion link

    func startCompanion() {
        Task.detached { [weak self] in
            do {
                let secret = try PairingSecret.loadOrCreate(in: FileSecretStore())
                let server = CompanionServer(secret: secret)
                server.onEvent = { event in Task { @MainActor in self?.handleCompanion(event) } }
                server.onConnectionChange = { connected in Task { @MainActor in self?.companionConnectionChanged(connected) } }
                let port = try server.start(preferredPort: AppModel.preferredCompanionPort)
                await MainActor.run {
                    self?.companion = server
                    self?.currentServer.set(server)
                    self?.companionPort = port
                    self?.companionError = nil
                }
            } catch {
                await MainActor.run { self?.companionError = "Companion link could not start: \(error)" }
            }
        }
    }

    /// Privacy-safe diagnostics at ~/Library/Logs/DroidMirror/companion.log: events, app names and text lengths only, never message text.
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DroidMirror")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("companion.log")
    }()

    /// Opens the activity log in the default app (Console or a text editor).
    func openLog() {
        if !FileManager.default.fileExists(atPath: Self.logURL.path) { try? Data().write(to: Self.logURL) }
        NSWorkspace.shared.open(Self.logURL)
    }

    private func log(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: Self.logURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: Self.logURL)
        }
    }

    private func companionConnectionChanged(_ connected: Bool) {
        log("phone \(connected ? "connected" : "disconnected")")
        if !connected { currentPhone.set(nil) }
        companionConnected = connected
        if !connected { companionPhoneName = nil }
    }

    private func handleCompanion(_ event: PhoneToMac) {
        switch event {
        case .hello(let name, _):
            log("hello from \(name)")
            currentPhone.set(name)
            companionPhoneName = name
        case .notification(let n):
            notificationStore.add(n)
            refreshRecent()
            // The phone may re-post the same notification; only alert when the content changed.
            let signature = "\(n.title ?? "")|\(n.text ?? "")"
            let isNew = postedSignatures[n.key] != signature
            if postedSignatures.count > 1000 { postedSignatures.removeAll() }
            postedSignatures[n.key] = signature
            let willAlert = isNew && forwardNotifications
            log("notification from \(n.app): title_len=\(n.title?.count ?? 0) text_len=\(n.text?.count ?? 0) canReply=\(n.canReply) macAlert=\(willAlert)")
            if willAlert { Notifier.post(n) }
        case .dismissed(let key):
            log("notification dismissed on phone")
            notificationStore.remove(key: key)
            postedSignatures.removeValue(forKey: key)
            refreshRecent()
        case .pong, .unknown:
            break
        }
    }

    private func refreshRecent() { recentNotifications = notificationStore.list(limit: 8) }

    /// Asks the phone to dismiss a notification. The Mac list updates at once; the phone confirms with its own "dismissed" event.
    func dismissOnPhone(_ n: CompanionNotification) {
        guard companionConnected else { return }
        companion?.send(.action(key: n.key, kind: .dismiss, text: nil))
        notificationStore.remove(key: n.key)
        postedSignatures.removeValue(forKey: n.key)
        refreshRecent()
        log("dismiss requested for a notification from \(n.app)")
    }

    /// Sends a typed reply to the phone, which fills the notification's reply box for the original app.
    func sendReply(to n: CompanionNotification, text: String) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, companionConnected else { return }
        companion?.send(.action(key: n.key, kind: .reply, text: reply))
        log("reply sent to \(n.app): text_len=\(reply.count)")
    }

    /// The text the QR code carries (host, port, secret). Nil until the server is listening and the Mac is on a network.
    func pairingPayloadJSON() -> String? {
        guard let port = companionPort, let ip = LocalNetwork.lanIPv4(), let secret = FileSecretStore().load() else { return nil }
        return try? PairingPayload(host: ip, port: Int(port), secret: secret, name: Host.current().localizedName ?? "Mac").json()
    }

    var pairingAddress: String? {
        guard let port = companionPort, let ip = LocalNetwork.lanIPv4() else { return nil }
        return "\(ip):\(port)"
    }

    /// Copies the pairing code (for the app's "Paste pairing code" option) and clears the clipboard after 60 s.
    func copyPairingCode() {
        guard let json = pairingPayloadJSON() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: .string)
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if pb.changeCount == count { pb.clearContents() } }
    }

    /// Makes a new secret, which disconnects and unpairs the current phone.
    func resetPairing() {
        companion?.stop()
        companion = nil
        currentServer.set(nil)
        currentPhone.set(nil)
        companionPort = nil
        companionConnected = false
        companionPhoneName = nil
        notificationStore.clear()
        recentNotifications = []
        replyTarget = nil
        postedSignatures.removeAll()
        do { try FileSecretStore().save(PairingSecret.generate()) } catch { companionError = "Could not reset pairing: \(error)"; return }
        startCompanion()
    }

    /// Starts the local socket that the MCP bridge uses. What it may do is decided by the two menu switches above.
    private func startControl() {
        let serverBox = currentServer, phoneBox = currentPhone
        let api = NotificationAPI(store: notificationStore, hooks: .init(
            canRead: { UserDefaults.standard.bool(forKey: "toolsMayRead") },
            canAct: { UserDefaults.standard.bool(forKey: "toolsMayAct") },
            isConnected: { serverBox.get()?.isConnected ?? false },
            phoneName: { phoneBox.get() },
            send: { serverBox.get()?.send($0) },
            confirmReply: { askToConfirmReply($0, $1) },
            didChange: { [weak self] in Task { @MainActor in self?.refreshRecent() } },
            log: { [weak self] message in Task { @MainActor in self?.log(message) } }
        ))
        Task.detached { [weak self] in
            let server = ControlServer(api: api)
            do {
                try server.start()
                await MainActor.run { self?.controlServer = server }
            } catch {
                await MainActor.run { self?.companionError = "Tool socket could not start: \(error)" }
            }
        }
    }

    func connect(_ device: AndroidDevice) {
        guard device.isReady, process == nil else { return }
        var options = MirrorOptions(serial: device.serial)
        options.screenOff = screenOff
        do {
            process = try Scrcpy.launch(options)
            mirroringSerial = device.serial
            errorMessage = nil
        } catch {
            errorMessage = "\(error)"
        }
    }

    func discoverMdns() {
        Task { mdnsServices = await Task.detached { WiFi.discover() }.value }
    }

    func pair(endpoint: String, code: String) {
        wifiStatus = "Pairing…"
        Task {
            let r = await Task.detached { WiFi.pair(endpoint: endpoint, code: code) }.value
            wifiStatus = (r.success ? "Paired. Now connect. " : "Pairing failed: ") + r.message
        }
    }

    func connectWiFi(endpoint: String) {
        wifiStatus = "Connecting…"
        Task {
            let r = await Task.detached { WiFi.connect(endpoint: endpoint) }.value
            wifiStatus = r.message
            if r.success {
                var list = recentEndpoints.filter { $0 != endpoint }
                list.insert(endpoint, at: 0)
                recentEndpoints = Array(list.prefix(5))
                UserDefaults.standard.set(recentEndpoints, forKey: "recentEndpoints")
                refresh()
            }
        }
    }

    func disconnect() {
        process?.terminate()
        process = nil
        mirroringSerial = nil
    }
}
