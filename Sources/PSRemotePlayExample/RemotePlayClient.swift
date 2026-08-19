import Combine
import Foundation

/// Drives a PlayStation Remote Play session end to end, and hands the controller to whatever
/// input sources you register.
///
/// The order of operations is fixed by the protocol and worth knowing:
///
/// 1. **Sign in** once to a PSN account, to obtain the account id the console checks against.
/// 2. **Discover** consoles on the LAN over UDP broadcast.
/// 3. **Register** a console once, with the 8-digit PIN from its Link Device screen. This yields
///    a registration key that grants control from then on, so it is kept in the keychain.
/// 4. **Connect**, which negotiates a session over HTTP, then opens the Takion UDP stream that
///    carries video, audio and controller input.
///
/// Steps 1–3 happen once per console. Everyday use is only step 4.
@MainActor
final class RemotePlayClient: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
    }

    /// Resolution and bitrate are agreed when the session starts and cannot change while it runs,
    /// so choosing a different one takes effect on the next connection.
    enum Quality: String, CaseIterable, Identifiable {
        case low, medium, high

        var id: String { rawValue }
        var label: String {
            switch self {
            case .low: return "360p"
            case .medium: return "720p"
            case .high: return "1080p"
            }
        }
        var size: (width: Int, height: Int) {
            switch self {
            case .low: return (640, 360)
            case .medium: return (1280, 720)
            case .high: return (1920, 1080)
            }
        }
        var bitrateKbps: Int {
            switch self {
            case .low: return 5_000
            case .medium: return 12_000
            case .high: return 20_000
            }
        }
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var account: RPAccount?
    @Published private(set) var hosts: [RPRegisteredHost] = []
    @Published private(set) var discovered: [RPHostStatus] = []
    @Published private(set) var lastError: String?
    @Published var quality: Quality = .medium
    @Published var showVideo = false {
        didSet {
            av.isVideoEnabled = showVideo
            av.isAudioEnabled = showVideo && playAudio
            if showVideo { videoWindow.show() } else { videoWindow.close() }
        }
    }
    @Published var playAudio = true {
        didSet { av.isAudioEnabled = showVideo && playAudio }
    }

    let av = RemotePlayAV()
    let videoWindow = RemotePlayVideoWindowController()
    /// A physical controller, wired through the same input layer your own source uses. It is here
    /// as a worked example as much as a feature.
    let gamepad = RPGamepadSource()

    private let store = RPStore()
    private let queue = DispatchQueue(label: "com.example.psremoteplay.session")
    private var session: RPSession?
    private var stream: RPStream?
    private var controller: RPController?
    private var sources: [RemotePlayInputSource] = []

    init() {
        let contents = store.load()
        account = contents.account
        hosts = contents.hosts
        connectVideoWindow()
    }

    // MARK: - Input sources

    /// Add a source. It is handed a controller whenever a session is up, and told when one goes
    /// away. Register as many as you like: they merge rather than override.
    func addInputSource(_ source: RemotePlayInputSource) {
        sources.append(source)
        if let controller {
            source.remotePlayDidConnect(
                RemotePlayControllerBinding(controller: controller, source: .custom))
        }
    }

    // MARK: - Sign in

    /// Where to send the user to log in. They land on a blank redirect page; its URL carries the
    /// authorization code, which is why `completeSignIn` takes the whole URL.
    var signInURL: URL { RPOAuth.loginURL }

    func completeSignIn(redirectURL: String) async {
        guard let url = URL(string: redirectURL),
            let code = RPOAuth.authorizationCode(from: url)
        else {
            lastError = "That URL has no authorization code in it."
            return
        }
        do {
            let account = try await RPOAuth.fetchAccount(code: code)
            self.account = account
            persist()
            lastError = nil
        } catch {
            lastError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Discovery and registration

    func search() async {
        discovered = await RPDiscovery.search()
        if discovered.isEmpty { lastError = "No consoles answered on this network." }
    }

    /// Link a console. The PIN is on the console under Settings → Remote Play → Link Device.
    func register(_ status: RPHostStatus, pin: String) async {
        guard let account else {
            lastError = "Sign in first — the console checks the account id."
            return
        }
        do {
            let host = try await RPRegistrar.register(
                status: status, psnAccountId: account.accountId, pin: pin)
            hosts.removeAll { $0.hostId == host.hostId }
            hosts.append(host)
            persist()
            lastError = nil
        } catch {
            lastError = "Registration failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Session

    func connect(to host: RPRegisteredHost) async {
        if state != .disconnected { disconnect() }
        state = .connecting(host.name)
        lastError = nil

        guard let status = await locate(host) else {
            fail("\(host.name) was not found on the network.")
            return
        }
        guard status.isOn else {
            RPDiscovery.wake(
                host: status.hostIP, hostType: status.hostType,
                credential: RPDiscovery.wakeCredential(registKey: host.registKey) ?? "")
            fail("Console is in rest mode; sent a wake request. Try again in ~20 seconds.")
            return
        }

        let session = RPSession(
            host: status.hostIP, hostType: status.hostType, registKey: host.registKey,
            rpKey: host.rpKeyBytes, queue: queue)
        self.session = session
        session.onStopped = { [weak self] reason in
            Task { @MainActor in self?.sessionDidStop(reason) }
        }

        do {
            // A console that has just ended a session refuses the next one for about 15 seconds.
            // Production code should retry here; the example reports it so the cause is visible.
            let sessionId = try await session.start()
            guard let cipher = session.cipher else { throw RPError.authFailed("no cipher") }

            let stream = RPStream(
                host: status.hostIP, hostType: status.hostType, sessionId: sessionId,
                sessionCipher: cipher, queue: queue,
                videoWidth: quality.size.width, videoHeight: quality.size.height,
                bitrateKbps: quality.bitrateKbps)
            self.stream = stream
            stream.av = av
            av.reset()
            stream.onStopped = { [weak self] reason in
                Task { @MainActor in self?.sessionDidStop(reason) }
            }

            try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                stream.onReady = {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume()
                }
                do { try stream.start() } catch {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: error)
                }
            }

            let controller = RPController(stream: stream)
            self.controller = controller
            state = .connected(host.name)
            attachSources(to: controller)
        } catch {
            fail("Could not connect: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        detachSources()
        controller = nil
        av.reset()
        let stream = self.stream
        let session = self.session
        self.stream = nil
        self.session = nil
        stream?.onStopped = nil
        session?.onStopped = nil
        stream?.stop()
        session?.stop()
        state = .disconnected
    }

    /// The console keeps a session open until its client disconnects, so quitting while connected
    /// leaves it occupied and refuses the next connection until it times out on its own.
    func disconnectBeforeQuitting() {
        stream?.stopBlocking()
        session?.stop()
    }

    // MARK: - Internals

    private func attachSources(to controller: RPController) {
        for source in sources {
            source.remotePlayDidConnect(
                RemotePlayControllerBinding(controller: controller, source: .custom))
        }
        gamepad.forward(to: controller)
    }

    private func detachSources() {
        for source in sources { source.remotePlayDidDisconnect() }
        gamepad.forward(to: nil)
    }

    private func sessionDidStop(_ reason: String) {
        guard state != .disconnected else { return }
        lastError = "Session ended: \(reason)"
        disconnect()
    }

    private func fail(_ message: String) {
        lastError = message
        disconnect()
    }

    private func locate(_ host: RPRegisteredHost) async -> RPHostStatus? {
        if let address = host.lastAddress, let status = await RPDiscovery.status(of: address) {
            return status
        }
        return await RPDiscovery.search().first { $0.hostId == host.hostId }
    }

    private func persist() {
        _ = store.save(RPStore.Contents(account: account, hosts: hosts))
    }

    private func connectVideoWindow() {
        av.onFrame = { [weak self] sample in
            MainActor.assumeIsolated { self?.videoWindow.enqueue(sample) }
        }
        av.onFormat = { [weak self] size in
            MainActor.assumeIsolated { self?.videoWindow.adoptVideoSize(size) }
        }
        videoWindow.statusProvider = { [weak self] in
            guard let self else { return "" }
            let stats = self.av.stats
            return "packets \(stats.packetsSeen) · decoded \(stats.decodedFrames)"
        }
        // Keyboard input from the video window is its own source, so it cannot cancel a button
        // your device is holding.
        videoWindow.onButton = { [weak self] button, pressed in
            MainActor.assumeIsolated {
                guard let controller = self?.controller else { return }
                if pressed {
                    controller.press(button, from: .gamepad)
                } else {
                    controller.release(button, from: .gamepad)
                }
            }
        }
        videoWindow.onToggleAudio = { [weak self] in
            MainActor.assumeIsolated { self?.playAudio.toggle() }
        }
        videoWindow.onVolume = { [weak self] volume in
            MainActor.assumeIsolated { self?.av.audioVolume = volume }
        }
        videoWindow.onClose = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showVideo else { return }
                self.showVideo = false
            }
        }
    }
}
