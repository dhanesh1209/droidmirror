import Foundation

public struct MirrorOptions: Equatable, Sendable {
    public var serial: String?
    public var screenOff = true        // "locked phone" mode: mirror while the phone display is dark
    public var stayAwake = true
    public var audio = true
    public var control = true
    public var maxSize: Int? = nil
    public var windowTitle: String? = "DroidMirror"

    public init(serial: String? = nil) { self.serial = serial }

    /// Builds the scrcpy argument list. Pure function so it is testable without a device.
    public var arguments: [String] {
        var a: [String] = []
        if let serial { a += ["--serial", serial] }
        if screenOff { a.append("--turn-screen-off") }
        if stayAwake { a.append("--stay-awake") }
        if !audio { a.append("--no-audio") }
        if !control { a.append("--no-control") }
        if let maxSize { a += ["--max-size", String(maxSize)] }
        if let windowTitle { a += ["--window-title", windowTitle] }
        return a
    }
}

public enum Scrcpy {
    /// Starts scrcpy and returns the running process (caller owns its lifetime).
    @discardableResult
    public static func launch(_ options: MirrorOptions) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["scrcpy"] + options.arguments
        try p.run()
        return p
    }
}
