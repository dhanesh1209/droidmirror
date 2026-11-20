import SwiftUI
import DroidMirrorCore

/// Lets you type a reply to a phone notification. The text goes to the phone over the encrypted link.
struct ReplyView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let n = model.replyTarget {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reply on \(n.app)").font(.title3.weight(.semibold))
                    if let title = n.title { Text(title).font(.headline) }
                    if let body = n.text { Text(body).foregroundStyle(.secondary).lineLimit(4) }
                }
                TextField("Your reply", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { send(n) }
                HStack {
                    if !model.companionConnected {
                        Label("Phone not connected", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    Button("Send") { send(n) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.companionConnected)
                }
            } else {
                Text("Nothing to reply to.").foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func send(_ n: CompanionNotification) {
        model.sendReply(to: n, text: text)
        close()
    }

    private func close() {
        text = ""
        model.replyTarget = nil
        dismiss()
    }
}
