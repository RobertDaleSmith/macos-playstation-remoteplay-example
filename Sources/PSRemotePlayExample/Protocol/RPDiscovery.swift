import Foundation

/// Device Discovery Protocol: find consoles on the LAN, read their status, wake them.
enum RPDiscovery {
    private static let queue = DispatchQueue(label: "com.example.psremoteplay.ddp")

    static func searchMessage() -> [UInt8] {
        Array("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:\(RPConstants.ddpVersion)\n".utf8)
    }

    static func wakeMessage(credential: String) -> [UInt8] {
        let text =
            "WAKEUP * HTTP/1.1\n"
            + "user-credential:\(credential)\n"
            + "client-type:vr\n"
            + "auth-type:R\n"
            + "model:w\n"
            + "app-type:r\n"
            + "device-discovery-protocol-version:\(RPConstants.ddpVersion)\n"
        return Array(text.utf8)
    }

    /// IPv4 broadcast addresses of every active interface (e.g. 192.168.1.255).
    ///
    /// Some networks and Wi-Fi drivers drop the limited broadcast address (255.255.255.255), so a
    /// search sends to each interface's directed broadcast as well.
    static func directedBroadcastAddresses() -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return addresses }
        defer { freeifaddrs(head) }
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                let addr = ifa.pointee.ifa_dstaddr, addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var storage = sockaddr_in()
            memcpy(&storage, addr, MemoryLayout<sockaddr_in>.size)
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = storage.sin_addr
            inet_ntop(AF_INET, &sin, &text, socklen_t(INET_ADDRSTRLEN))
            let value = String(cString: text)
            if !value.isEmpty, value != "0.0.0.0", !addresses.contains(value) {
                addresses.append(value)
            }
        }
        return addresses
    }

    /// Broadcast (or unicast to `host`) a search and collect every console that answers.
    static func search(host: String? = nil, timeout: TimeInterval = 2.0) async -> [RPHostStatus] {
        await withCheckedContinuation { (cont: CheckedContinuation<[RPHostStatus], Never>) in
            queue.async {
                let socket: RPUDPSocket
                do {
                    socket = try RPUDPSocket(
                        queue: queue, localPort: RPConstants.ddpLocalPort, reusePort: true,
                        broadcast: host == nil)
                } catch {
                    rpLogger.error("DDP socket: \(error.localizedDescription)")
                    cont.resume(returning: [])
                    return
                }
                lastSearchWasBlocked = false
                var found: [String: RPHostStatus] = [:]
                var finished = false
                let target = host ?? RPConstants.broadcastAddress
                let finish = {
                    guard !finished else { return }
                    finished = true
                    socket.close()
                    cont.resume(returning: Array(found.values).sorted { $0.hostName < $1.hostName })
                }
                socket.startReceiving { bytes, from, _ in
                    guard let text = String(bytes: bytes, encoding: .utf8),
                        let status = RPHostStatus.parse(text, remoteAddress: from)
                    else { return }
                    if let host, host != from { return }
                    found[from] = status
                    if host != nil { finish() }
                }
                let message = searchMessage()
                // Unicast when a host was named; otherwise limited broadcast plus every
                // interface's directed broadcast, since some networks drop 255.255.255.255.
                var targets = [target]
                if host == nil { targets += directedBroadcastAddresses() }
                for address in targets {
                    for type in [RPHostType.ps5, .ps4] {
                        socket.send(message, to: address, port: type.ddpPort)
                    }
                }
                rpLogger.info(
                    "DDP search from port \(socket.localPort) to \(targets.joined(separator: ", "))"
                )
                queue.asyncAfter(deadline: .now() + timeout) {
                    if found.isEmpty {
                        // EHOSTUNREACH/EPERM on every send means the sandbox refused the LAN, not
                        // that nothing answered.
                        let e = socket.lastSendErrno
                        lastSearchWasBlocked = e == EHOSTUNREACH || e == EPERM || e == ENETDOWN
                        if lastSearchWasBlocked {
                            rpLogger.error(
                                "DDP search blocked by local network policy (errno \(e)). Turn this app on under System Settings → Privacy & Security → Local Network."
                            )
                        } else {
                            rpLogger.error("DDP search found no consoles.")
                        }
                    }
                    finish()
                }
            }
        }
    }

    /// True when the last search was refused by the sandbox rather than simply finding nothing.
    private(set) nonisolated(unsafe) static var lastSearchWasBlocked = false

    static func status(of host: String, timeout: TimeInterval = 2.0) async -> RPHostStatus? {
        await search(host: host, timeout: timeout).first
    }

    /// Send a wake packet. `credential` is the decimal form of the registration key.
    static func wake(host: String, hostType: RPHostType, credential: String) {
        queue.async {
            guard
                let socket = try? RPUDPSocket(
                    queue: queue, localPort: RPConstants.ddpLocalPort, reusePort: true)
            else { return }
            socket.send(wakeMessage(credential: credential), to: host, port: hostType.ddpPort)
            queue.asyncAfter(deadline: .now() + 0.5) { socket.close() }
        }
    }

    /// The wake credential derived from a registration key: the key is hex of an ASCII hex
    /// string; decode both layers and render the resulting integer in decimal.
    static func wakeCredential(registKey: String) -> String? {
        guard let outer = [UInt8](hexString: registKey),
            let ascii = String(bytes: outer, encoding: .ascii),
            let inner = [UInt8](hexString: ascii)
        else { return nil }
        var value: UInt64 = 0
        for b in inner { value = (value << 8) | UInt64(b) }
        return String(value)
    }
}
