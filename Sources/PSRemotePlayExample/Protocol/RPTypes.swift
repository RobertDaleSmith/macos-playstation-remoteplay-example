import Foundation
import OSLog

let rpLogger = Logger(subsystem: "com.example.psremoteplay", category: "RemotePlay")

/// Console generation. Determines ports, key tables and protocol version strings.
enum RPHostType: String, Codable, Equatable {
    case ps4 = "PS4"
    case ps5 = "PS5"

    /// Device Discovery Protocol port the console listens on.
    var ddpPort: UInt16 { self == .ps5 ? 9302 : 987 }

    /// `RP-Version` header value.
    var rpVersion: String { self == .ps5 ? "1.0" : "10.0" }

    var pathSlug: String { self == .ps5 ? "ps5" : "ps4" }

    /// Where the PIN pairing screen lives in the console's own menus. The two generations put it
    /// in completely different places, so telling a PS4 user to look under System → Remote Play
    /// sends them hunting for a menu that doesn't exist.
    var linkDeviceMenuPath: String {
        self == .ps5
            ? "Settings → System → Remote Play → Link Device"
            : "Settings → Remote Play Connection Settings → Add Device"
    }

    init?(statusValue: String) {
        switch statusValue.uppercased() {
        case "PS5": self = .ps5
        case "PS4": self = .ps4
        default: return nil
        }
    }
}

enum RPConstants {
    static let rpPort: UInt16 = 9295
    static let streamPort: UInt16 = 9296
    static let ddpLocalPort: UInt16 = 9303  // PS5 replies only to this source port
    static let userAgent = "remoteplay Windows"
    static let osType = "Win10.0.0"
    static let ddpVersion = "00030010"
    static let broadcastAddress = "255.255.255.255"
}

/// Parsed Device Discovery Protocol status response.
struct RPHostStatus: Equatable, Identifiable {
    var id: String { hostId }

    /// MAC-derived identifier the console reports as `host-id`.
    let hostId: String
    let hostName: String
    let hostType: RPHostType
    let hostIP: String
    let statusCode: Int
    let status: String
    let runningAppName: String?
    let runningAppTitleId: String?
    let systemVersion: String?
    let raw: [String: String]

    /// Consoles report their id inconsistently — discovery uses upper-case hex, the registration
    /// response's `Mac` field is lower-case, and separators show up in some firmware. Compare and
    /// store the canonical form so the same console is never treated as two.
    static func normalizeHostId(_ raw: String) -> String {
        raw.uppercased().filter { $0.isHexDigit }
    }

    static let statusOK = 200
    static let statusStandby = 620

    var isOn: Bool { statusCode == RPHostStatus.statusOK }
    var isStandby: Bool { statusCode == RPHostStatus.statusStandby }

    /// Parse a DDP response body. Returns nil for search echoes and non-status payloads.
    static func parse(_ text: String, remoteAddress: String) -> RPHostStatus? {
        if text.contains("SRCH") { return nil }
        var fields: [String: String] = [:]
        var statusCode: Int?
        var statusText = ""
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("HTTP/1.1 ") {
                let parts = line.dropFirst("HTTP/1.1 ".count).split(
                    separator: " ", maxSplits: 1)
                if let code = parts.first, let value = Int(code) {
                    statusCode = value
                    statusText = parts.count > 1 ? String(parts[1]) : ""
                }
                continue
            }
            // `running-app-name` may itself contain ':' so split on the first only.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            fields[key] = value
        }
        guard let code = statusCode, let hostId = fields["host-id"],
            let typeValue = fields["host-type"], let hostType = RPHostType(statusValue: typeValue)
        else { return nil }
        return RPHostStatus(
            hostId: normalizeHostId(hostId),
            hostName: fields["host-name"] ?? hostId,
            hostType: hostType,
            hostIP: remoteAddress,
            statusCode: code,
            status: statusText,
            runningAppName: fields["running-app-name"],
            runningAppTitleId: fields["running-app-titleid"],
            systemVersion: fields["system-version"],
            raw: fields)
    }
}

enum RPError: LocalizedError, Equatable {
    case hostUnreachable(String)
    case hostNotRegistered
    case hostInStandby
    case notInRegisterMode(RPHostType)
    case registrationFailed(String)
    case authFailed(String)
    case invalidResponse(String)
    case sessionClosed(String)
    case handshakeFailed(String)
    case notConnected
    case oauthFailed(String)
    case timeout(String)
    case localNetworkBlocked

    var errorDescription: String? {
        switch self {
        case .hostUnreachable(let host): return "Console at \(host) is not reachable."
        case .hostNotRegistered: return "This console is not linked to the signed-in PSN account."
        case .hostInStandby: return "Console is in rest mode."
        case .notInRegisterMode(let hostType):
            return
                "Console is not accepting links. On the \(hostType.rawValue) go to \(hostType.linkDeviceMenuPath)."
        case .registrationFailed(let why): return "Linking failed: \(why)"
        case .authFailed(let why): return "Session authentication failed: \(why)"
        case .invalidResponse(let why): return "Unexpected response from console: \(why)"
        case .sessionClosed(let why): return "Session closed: \(why)"
        case .handshakeFailed(let why): return "Stream handshake failed: \(why)"
        case .notConnected: return "Not connected to a console."
        case .oauthFailed(let why): return "PSN sign-in failed: \(why)"
        case .timeout(let what): return "Timed out waiting for \(what)."
        case .localNetworkBlocked:
            return
                "macOS is blocking this app from reaching devices on this network. Turn this app on under System Settings → Privacy & Security → Local Network, then quit and reopen the app. If it is already on, switch it off and on again — the permission is tied to the app's signature and a rebuild can invalidate it."
        }
    }

    /// Map an `RP-Application-Reason` header value to a message.
    static func applicationReason(_ hex: String) -> String {
        switch UInt32(hex, radix: 16) {
        case 0x8010_8B09: return "Registering failed"
        case 0x8010_8B02: return "PSN ID does not exist on host"
        case 0x8010_8B10: return "Another Remote Play session is connected to the console"
        case 0x8010_8B15: return "Remote Play crashed on the console; restart it"
        case 0x8010_8B11: return "Remote Play versions do not match"
        default: return "Unknown error \(hex)"
        }
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let chars = [Character](hexString)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        self = out
    }
}

extension Data {
    var byteArray: [UInt8] { [UInt8](self) }
}

/// Big-endian integer packing helpers shared by the packet codecs.
enum RPBytes {
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    static func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> (56 - 8 * UInt64($0))) & 0xFF) }
    }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }
    static func readBE16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    static func readBE32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
    }
    static func readLE32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func random(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        return out
    }
}
