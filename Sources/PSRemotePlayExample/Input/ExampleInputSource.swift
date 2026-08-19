import Combine
import Foundation

/// A stand-in for whatever you are actually building.
///
/// It does nothing clever on purpose: the on-screen buttons in the demo call `tap`, `hold` and
/// `release`, and a "sweep" toggle walks the left stick in a circle so stick output is visible
/// without any hardware. Replace it with your own device and the rest of the project is unchanged.
///
/// Note what it does *not* have to know about: no session, no crypto, no packet format, no video.
/// It holds a `RemotePlayControllerInput` and calls methods on it.
@MainActor
final class ExampleInputSource: ObservableObject, RemotePlayInputSource {
    @Published private(set) var isConnected = false
    @Published private(set) var held: Set<String> = []
    @Published var isSweeping = false {
        didSet { isSweeping ? startSweep() : stopSweep() }
    }

    private var input: RemotePlayControllerInput?
    private var sweep: Timer?
    private var angle = 0.0

    // MARK: - RemotePlayInputSource

    nonisolated func remotePlayDidConnect(_ input: RemotePlayControllerInput) {
        Task { @MainActor in
            self.input = input
            self.isConnected = true
        }
    }

    nonisolated func remotePlayDidDisconnect() {
        Task { @MainActor in
            self.input = nil
            self.isConnected = false
            self.held.removeAll()
            self.isSweeping = false
        }
    }

    // MARK: - What a device would call

    /// Press and release, which is how a console reads a tap.
    func tap(_ button: RPTakion.Button) {
        input?.press(button)
        // Long enough for the console to see both edges as one press.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.input?.release(button)
        }
    }

    /// Hold until `release`. This is the part a naive integration usually gets wrong: firing a tap
    /// on every event means a charged attack or a held direction is impossible.
    func hold(_ button: RPTakion.Button, named name: String) {
        input?.press(button)
        held.insert(name)
    }

    func release(_ button: RPTakion.Button, named name: String) {
        input?.release(button)
        held.remove(name)
    }

    /// Continuous input. Write it as often as you sample it — the controller coalesces to 60Hz,
    /// so there is no need to rate-limit here.
    func moveStick(_ stick: RPController.Stick, x: Double, y: Double) {
        input?.setStick(stick, x: x, y: y)
    }

    private func startSweep() {
        sweep?.invalidate()
        sweep = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.angle += 0.05
                self.moveStick(.left, x: cos(self.angle), y: sin(self.angle))
            }
        }
    }

    private func stopSweep() {
        sweep?.invalidate()
        sweep = nil
        moveStick(.left, x: 0, y: 0)
    }
}
