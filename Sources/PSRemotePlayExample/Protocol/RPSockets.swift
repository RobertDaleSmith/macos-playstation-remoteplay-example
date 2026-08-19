import Foundation
import Network

/// Thin BSD UDP socket. Used where Network.framework is awkward: broadcast discovery, a fixed
/// local source port (the PS5 only answers discovery from port 9303) and the Takion stream.
final class RPUDPSocket {
    private(set) var fd: Int32 = -1
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private(set) var localPort: UInt16 = 0
    /// errno of the most recent failed send, so callers can tell a blocked network
    /// (EHOSTUNREACH/EPERM under the sandbox) from an ordinary miss.
    private(set) var lastSendErrno: Int32 = 0

    init(
        queue: DispatchQueue, localPort: UInt16 = 0, reusePort: Bool = false,
        broadcast: Bool = false
    )
        throws
    {
        self.queue = queue
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw RPError.invalidResponse("socket() failed: \(errno)") }
        // A video stream fills the default receive buffer in milliseconds. Anything the kernel
        // drops is gone before any of our code runs, and shows up as lost units we then have to
        // repair or discard whole frames for.
        var receiveBuffer: Int32 = 4 * 1024 * 1024
        setsockopt(
            sock, SOL_SOCKET, SO_RCVBUF, &receiveBuffer,
            socklen_t(MemoryLayout<Int32>.size))
        // The kernel may grant less than asked; report what it actually gave.
        var granted: Int32 = 0
        var grantedSize = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(sock, SOL_SOCKET, SO_RCVBUF, &granted, &grantedSize) == 0 {
            rpLogger.info("UDP receive buffer: \(granted) bytes")
        }
        fd = sock
        var one: Int32 = 1
        if reusePort {
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        if broadcast {
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = localPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        var bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 && localPort != 0 {
            // Fall back to an ephemeral port (another client may hold the requested one).
            addr.sin_port = 0
            bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            fd = -1
            throw RPError.invalidResponse("bind() failed: \(errno)")
        }
        var bound_addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound_addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.localPort = UInt16(bigEndian: bound_addr.sin_port)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    deinit { close() }

    static func address(_ host: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    @discardableResult
    func send(_ bytes: [UInt8], to host: String, port: UInt16) -> Bool {
        guard fd >= 0, var addr = RPUDPSocket.address(host, port: port) else { return false }
        let sent = bytes.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        fd, ptr.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            lastSendErrno = errno
            rpLogger.error("UDP sendto \(host):\(port) failed: \(errno)")
            return false
        }
        return true
    }

    /// Deliver every datagram to `handler` on the socket's queue.
    func startReceiving(_ handler: @escaping ([UInt8], String, UInt16) -> Void) {
        guard fd >= 0, source == nil else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let capacity = buffer.count
            while true {
                var from = sockaddr_in()
                var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = buffer.withUnsafeMutableBytes { ptr in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(self.fd, ptr.baseAddress, capacity, 0, $0, &fromLen)
                        }
                    }
                }
                if count <= 0 { break }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = from.sin_addr
                inet_ntop(AF_INET, &sin, &text, socklen_t(INET_ADDRSTRLEN))
                let host = String(cString: text)
                handler(Array(buffer[0..<count]), host, UInt16(bigEndian: from.sin_port))
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self, self.fd >= 0 else { return }
            Darwin.close(self.fd)
            self.fd = -1
        }
        source = src
        src.resume()
    }

    func close() {
        if let source {
            source.cancel()
            self.source = nil
        } else if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// Async TCP connection over Network.framework with a small HTTP/1.1 request helper.
final class RPTCPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private(set) var isOpen = false

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.queue = queue
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    /// True when the failure is macOS refusing local-network access, not the peer being absent.
    static func isLocalNetworkBlocked(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .ENETDOWN || code == .EHOSTUNREACH || code == .EPERM
        }
        return false
    }

    func connect(timeout: TimeInterval = 10) async throws {
        let endpoint = "\(connection.endpoint)"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            var sawWaiting = false
            var blocked = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting(let error):
                    // A sandboxed app denied Local Network access sees ENETDOWN/EHOSTUNREACH here
                    // rather than a refusal, so classify it instead of waiting out the timeout.
                    sawWaiting = true
                    if RPTCPConnection.isLocalNetworkBlocked(error) { blocked = true }
                    rpLogger.error("TCP \(endpoint) waiting: \(error.localizedDescription)")
                case .preparing:
                    rpLogger.debug("TCP \(endpoint) preparing")
                default:
                    break
                }
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    self?.isOpen = true
                    rpLogger.info("TCP \(endpoint) connected")
                    cont.resume()
                case .failed(let error):
                    resumed = true
                    rpLogger.error("TCP \(endpoint) failed: \(error.localizedDescription)")
                    cont.resume(throwing: RPError.hostUnreachable(error.localizedDescription))
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: RPError.sessionClosed("cancelled"))
                default: break
                }
            }
            connection.start(queue: queue)
            // A permission block is not transient; don't make the user wait out the timeout.
            queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard !resumed, blocked else { return }
                resumed = true
                self?.connection.cancel()
                rpLogger.error("TCP \(endpoint) blocked by local network policy")
                cont.resume(throwing: RPError.localNetworkBlocked)
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !resumed else { return }
                resumed = true
                self?.connection.cancel()
                rpLogger.error(
                    "TCP \(endpoint) timed out after \(timeout)s (waiting=\(sawWaiting))")
                cont.resume(
                    throwing: RPError.timeout(
                        sawWaiting
                            ? "the console to accept a connection. It may still be finishing a previous Remote Play session — wait ~15 seconds. If it never connects, allow this app under System Settings → Privacy & Security → Local Network"
                            : "TCP connect"))
            }
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(bytes),
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: RPError.sessionClosed(error.localizedDescription))
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    /// Receive up to `max` bytes. Returns an empty array when the peer closes the connection.
    func receive(max: Int = 65536, timeout: TimeInterval = 5) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[UInt8], Error>) in
            var resumed = false
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) {
                data, _, isComplete, error in
                guard !resumed else { return }
                resumed = true
                if let error {
                    cont.resume(throwing: RPError.sessionClosed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data.byteArray)
                } else if isComplete {
                    cont.resume(returning: [])
                } else {
                    cont.resume(returning: [])
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                guard !resumed else { return }
                resumed = true
                cont.resume(throwing: RPError.timeout("TCP receive"))
            }
        }
    }

    /// Continuously deliver received bytes on the connection queue until closed.
    func startReceiving(
        _ handler: @escaping ([UInt8]) -> Void, onClose: @escaping (String?) -> Void
    ) {
        func loop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { handler(data.byteArray) }
                if let error {
                    self.isOpen = false
                    onClose(error.localizedDescription)
                    return
                }
                if isComplete {
                    self.isOpen = false
                    onClose(nil)
                    return
                }
                loop()
            }
        }
        loop()
    }

    func cancel() {
        isOpen = false
        connection.cancel()
    }
}

/// Minimal HTTP/1.1 response parsing for the console's registration/session endpoints.
struct RPHTTPResponse {
    let statusCode: Int
    let statusText: String
    let headers: [String: String]  // lower-cased keys
    let body: [UInt8]  // bytes after the header terminator that were already received

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Parse the head of an HTTP response if the header terminator has arrived. Returns nil while
    /// more bytes are needed.
    static func parse(_ bytes: [UInt8]) -> RPHTTPResponse? {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let end = bytes.firstRange(of: terminator) else { return nil }
        let headBytes = Array(bytes[0..<end.lowerBound])
        let body = Array(bytes[end.upperBound...])
        guard let head = String(bytes: headBytes, encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        return RPHTTPResponse(
            statusCode: code, statusText: parts.count > 2 ? parts[2] : "", headers: headers,
            body: body)
    }
}

extension RPTCPConnection {
    /// Send a request and read until the response headers are complete.
    func request(_ raw: String, timeout: TimeInterval = 5) async throws -> RPHTTPResponse {
        try await send(Array(raw.utf8))
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = try await receive(timeout: max(0.1, deadline.timeIntervalSinceNow))
            if chunk.isEmpty {
                if let response = RPHTTPResponse.parse(buffer) { return response }
                throw RPError.invalidResponse("connection closed before HTTP headers")
            }
            buffer += chunk
            if let response = RPHTTPResponse.parse(buffer) { return response }
        }
        throw RPError.timeout("HTTP response")
    }
}
