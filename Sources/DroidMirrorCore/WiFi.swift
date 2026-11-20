import Foundation

public struct MdnsService: Equatable, Sendable {
    public enum Kind: Sendable { case pairing, connect }
    public let name: String
    public let kind: Kind
    public let endpoint: String
}

public struct WiFiResult: Equatable, Sendable {
    public let success: Bool
    public let message: String
}

/// Wireless debugging (Android 11+): `adb pair`, `adb connect`, and mDNS discovery.
public enum WiFi {
    /// Accepts `host:port` where host is an IPv4 address or hostname. Rejects anything that could be read as an adb option.
    public static func isValidEndpoint(_ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9.\-]*:[0-9]{1,5}$"#),
              re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil,
              let port = Int(s.split(separator: ":").last ?? ""), (1...65535).contains(port)
        else { return false }
        return true
    }

    public static func isValidPairingCode(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy(\.isNumber) && s.allSatisfy(\.isASCII)
    }

    /// `adb pair` and `adb connect` exit 0 even when they fail, so success is read from the output.
    public static func interpretPair(_ output: String) -> WiFiResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return WiFiResult(success: text.localizedCaseInsensitiveContains("successfully paired"), message: text)
    }

    public static func interpretConnect(_ output: String) -> WiFiResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = (text.hasPrefix("connected to") || text.hasPrefix("already connected to"))
        return WiFiResult(success: ok, message: text)
    }

    /// Parses `adb mdns services` lines: `<name>\t<_adb-tls-pairing|_adb-tls-connect>._tcp.\t<host:port>`.
    public static func parseMdnsServices(_ output: String) -> [MdnsService] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 3, isValidEndpoint(parts[2]) else { return nil }
            let kind: MdnsService.Kind
            if parts[1].contains("_adb-tls-pairing") { kind = .pairing }
            else if parts[1].contains("_adb-tls-connect") { kind = .connect }
            else { return nil }
            return MdnsService(name: parts[0], kind: kind, endpoint: parts[2])
        }
    }

    // MARK: - adb calls (blocking; run off the main thread)

    public static func pair(endpoint: String, code: String, adbPath: String = "adb") -> WiFiResult {
        guard isValidEndpoint(endpoint) else { return WiFiResult(success: false, message: "Invalid address. Use host:port, e.g. 192.168.1.20:39999.") }
        guard isValidPairingCode(code) else { return WiFiResult(success: false, message: "Pairing code must be 6 digits.") }
        do { return interpretPair(try ProcessRunner.run(adbPath, ["pair", endpoint, code])) }
        catch { return WiFiResult(success: false, message: "\(error)") }
    }

    public static func connect(endpoint: String, adbPath: String = "adb") -> WiFiResult {
        guard isValidEndpoint(endpoint) else { return WiFiResult(success: false, message: "Invalid address. Use host:port, e.g. 192.168.1.20:41234.") }
        do { return interpretConnect(try ProcessRunner.run(adbPath, ["connect", endpoint])) }
        catch { return WiFiResult(success: false, message: "\(error)") }
    }

    public static func discover(adbPath: String = "adb") -> [MdnsService] {
        guard let out = try? ProcessRunner.run(adbPath, ["mdns", "services"]) else { return [] }
        return parseMdnsServices(out)
    }
}
