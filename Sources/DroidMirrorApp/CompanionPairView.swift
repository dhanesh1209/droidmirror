import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import DroidMirrorCore

/// Pairing window for the no-USB-debugging companion link.
/// The QR code carries the pairing secret, so it is hidden while a phone is connected unless asked for.
struct CompanionPairView: View {
    @ObservedObject var model: AppModel
    @State private var confirmReset = false
    @State private var showQR = false

    private var qrVisible: Bool { !model.companionConnected || showQR }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair your phone").font(.title2.weight(.semibold))
            statusRow

            if qrVisible {
                qrSection
            } else {
                Button("Show QR code to pair another phone") { showQR = true }
                Text("The code is hidden because a phone is already connected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Copy pairing code") { model.copyPairingCode() }
                Spacer()
                Button("Reset pairing…", role: .destructive) { confirmReset = true }
            }
            Text("The QR code works like a password: anyone who sees it can pair as your phone. “Copy pairing code” clears your clipboard after 60 seconds.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 380)
        .onChange(of: model.companionConnected) { connected in
            if !connected { showQR = false }
        }
        .confirmationDialog("Reset pairing?", isPresented: $confirmReset) {
            Button("Reset and disconnect the phone", role: .destructive) { model.resetPairing() }
        } message: {
            Text("This creates a new secret. The phone will be disconnected and must be paired again.")
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: model.companionConnected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(model.companionConnected ? Color.green : Color.secondary)
            Text(model.companionConnected
                 ? "\((model.companionPhoneName ?? "Phone").replacingOccurrences(of: "_", with: "-")), connected"
                 : "No phone connected yet")
                .font(.callout)
        }
    }

    @ViewBuilder private var qrSection: some View {
        if let json = model.pairingPayloadJSON(), let image = Self.qrImage(json) {
            VStack(spacing: 12) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .frame(maxWidth: .infinity)
                Text("On your phone, open DroidMirror and tap “Scan QR code from your Mac”.")
                    .font(.callout)
                if let address = model.pairingAddress {
                    Text("Mac address  \(address)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } else if let error = model.companionError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else {
            Text("Starting… make sure this Mac is connected to Wi-Fi.").foregroundStyle(.secondary)
        }
    }

    /// Crisp, scaled-up QR image for a string.
    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
