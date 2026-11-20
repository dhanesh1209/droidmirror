import SwiftUI
import DroidMirrorCore

/// Wi-Fi mirroring setup (uses adb wireless debugging, not the companion link).
struct PairView: View {
    @ObservedObject var model: AppModel
    @State private var pairEndpoint = ""
    @State private var code = ""
    @State private var connectEndpoint = ""

    private let mono = Font.system(.body, design: .monospaced)

    var body: some View {
        Form {
            Section {
                Text("Wi-Fi mirroring needs Wireless debugging turned on in the phone’s Developer options. Notifications do not need this.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Step 1: Pair (once per Mac)") {
                Text("On the phone: Developer options, Wireless debugging, Pair device with pairing code.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.mdnsServices.filter { $0.kind == .pairing }, id: \.endpoint) { s in
                    Button("Use found address \(s.endpoint)") { pairEndpoint = s.endpoint }
                }
                TextField("Pairing address", text: $pairEndpoint, prompt: Text("192.168.1.20:37000")).font(mono)
                TextField("Code", text: $code, prompt: Text("6 digits")).font(mono)
                Button("Pair") { model.pair(endpoint: pairEndpoint, code: code) }
                    .disabled(!WiFi.isValidEndpoint(pairEndpoint) || !WiFi.isValidPairingCode(code))
            }
            Section("Step 2: Connect") {
                Text("Use the address on the main Wireless debugging screen, not the pairing one.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.mdnsServices.filter { $0.kind == .connect }, id: \.endpoint) { s in
                    Button("Use found address \(s.endpoint)") { connectEndpoint = s.endpoint }
                }
                ForEach(model.recentEndpoints, id: \.self) { e in
                    Button("Reconnect \(e)") { model.connectWiFi(endpoint: e) }
                }
                TextField("Connect address", text: $connectEndpoint, prompt: Text("192.168.1.20:41000")).font(mono)
                Button("Connect") { model.connectWiFi(endpoint: connectEndpoint) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!WiFi.isValidEndpoint(connectEndpoint))
            }
            if let s = model.wifiStatus {
                Section { Text(s).font(.callout).textSelection(.enabled) }
            }
            Section { Button("Search the network again") { model.discoverMdns() } }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { model.discoverMdns() }
    }
}
