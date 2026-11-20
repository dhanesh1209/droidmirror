import Foundation

public enum ProcessRunner {
    public struct Failure: Error, CustomStringConvertible {
        public let command: String
        public let status: Int32
        public let stderr: String
        public var description: String { "\(command) exited \(status): \(stderr)" }
    }

    /// Runs a tool found on PATH (or by absolute path) and returns stdout.
    public static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure(command: ([tool] + args).joined(separator: " "),
                          status: p.terminationStatus,
                          stderr: String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
