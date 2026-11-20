import AppKit
import Foundation
import DroidMirrorCore

/// A value readable from any thread (the control socket serves requests off the main thread).
final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

/// Asks the person at the Mac before a tool's reply is sent as them. Blocks the calling (non-main) thread until they answer.
/// There is deliberately no "always allow": a reply is a message sent in the user's name.
func askToConfirmReply(_ n: CompanionNotification, _ text: String) -> Bool {
    var allowed = false
    let show = {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Send this reply on \(n.app)?"
        alert.informativeText = "A program on this Mac (for example an AI agent) asked DroidMirror to reply from your phone:\n\n“\(text.prefix(300))”\n\nIt will be sent as you. Nothing is sent unless you choose Send."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        allowed = alert.runModal() == .alertFirstButtonReturn
    }
    if Thread.isMainThread { show() } else { DispatchQueue.main.sync(execute: show) }
    return allowed
}
