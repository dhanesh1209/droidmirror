import Foundation

public enum ToolCheck {
    /// True if `tool` is found on PATH.
    public static func isAvailable(_ tool: String) -> Bool {
        (try? ProcessRunner.run("which", [tool])) != nil
    }

    /// Names of required tools that are missing, e.g. ["scrcpy"].
    public static func missingRequiredTools() -> [String] {
        ["adb", "scrcpy"].filter { !isAvailable($0) }
    }
}
