import Foundation
import DroidMirrorCore

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "devices":
    do {
        let devices = try ADB.listDevices()
        if devices.isEmpty { print("No devices. Connect via USB and enable USB debugging.") }
        for d in devices {
            print("\(d.serial)\t\(d.state)\t\(d.model ?? "-")\t\(d.isWireless ? "wifi" : "usb")")
        }
    } catch { print("error: \(error)"); exit(1) }
case "mirror":
    do {
        let devices = try ADB.listDevices().filter(\.isReady)
        guard let d = devices.first else { print("No ready device."); exit(1) }
        print("Mirroring \(d.model ?? d.serial)…")
        let p = try Scrcpy.launch(MirrorOptions(serial: d.serial))
        p.waitUntilExit()
    } catch { print("error: \(error)"); exit(1) }
case "notifications":
    do {
        guard let d = try ADB.listDevices().first(where: \.isReady) else { print("No ready device."); exit(1) }
        let showAll = args.contains("--all")   // include system, ongoing and group-summary entries
        let filter = NotificationFilter()
        for n in try ADB.fetchNotifications(serial: d.serial) where showAll || filter.shouldForward(n) {
            print("\(n.appName)\t\(n.title ?? "-")\t\(n.text ?? "-")")
        }
    } catch { print("error: \(error)"); exit(1) }
case "companion":
    // Runs the Mac side of the companion link. Prints only app names and text lengths, never message text or the secret.
    do {
        let secret = try PairingSecret.loadOrCreate(in: FileSecretStore())
        let server = CompanionServer(secret: secret)
        @Sendable func log(_ s: String) {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            print("[\(f.string(from: Date()))] \(s)"); fflush(stdout)
        }
        server.onConnectionChange = { log("phone \($0 ? "connected" : "disconnected")") }
        server.onEvent = { event in
            switch event {
            case .hello(let name, let v): log("hello from \(name) (protocol \(v))")
            case .notification(let n): log("notification from \(n.app): title_len=\(n.title?.count ?? 0) text_len=\(n.text?.count ?? 0) canReply=\(n.canReply)")
            case .dismissed: log("notification dismissed on phone")
            case .pong: break
            case .unknown(let t): log("unknown message type: \(t)")
            }
        }
        let port = try server.start(preferredPort: 47891)
        guard let ip = LocalNetwork.lanIPv4() else { print("No LAN address found. Connect the Mac to Wi-Fi."); exit(1) }
        print("Listening on \(ip):\(port). Press Ctrl-C to stop.")
        if args.contains("--pair-via-adb") {
            // Debug shortcut: the debug build of the Android app accepts a base64 pairing payload from adb.
            let name = Host.current().localizedName ?? "Mac"
            let json = try PairingPayload(host: ip, port: Int(port), secret: secret, name: name).json()
            let b64 = Data(json.utf8).base64EncodedString()
            _ = try ProcessRunner.run("adb", ["shell", "am", "start", "-n", "dev.droidmirror.companion/.MainActivity", "--es", "pair_payload_b64", b64])
            print("Pairing code sent to the phone over adb.")
        }
        fflush(stdout)
        dispatchMain()
    } catch { print("error: \(error)"); exit(1) }
default:
    print("usage: droidmirror <devices|mirror|notifications|companion [--pair-via-adb]>")
}
