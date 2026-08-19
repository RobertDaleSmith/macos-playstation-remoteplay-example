import Foundation

/// Everything an input source can do to the console's controller.
///
/// This is the seam the example exists for. The rest of the project — discovery, registration,
/// the crypto handshake, the Takion transport, H.264 and Opus decoding — is protocol work that
/// nobody should have to write twice. What differs between one product and the next is only
/// *what decides to press the button*, and that is this protocol.
///
/// Every call is safe from any thread. Button events are sent immediately; stick positions are
/// coalesced to 60Hz, so a continuous signal can be written as fast as it is sampled without
/// flooding the console.
protocol RemotePlayControllerInput: AnyObject {
    /// Hold a button down. It stays held until `release`, which is what a console expects: a tap
    /// is a press and a release, and a charged attack is a press held across many frames.
    func press(_ button: RPTakion.Button)
    func release(_ button: RPTakion.Button)

    /// Stick position, each axis -1...1. Y is positive downward, as the console reads it.
    func setStick(_ stick: RPController.Stick, x: Double, y: Double)

    /// L2 or R2, 0...255. These are analog on a DualShock; a digital source should send 0 or 255.
    func setTrigger(_ trigger: RPTakion.Button, value: UInt8)

    /// Release everything this source is holding. Worth calling when your device disconnects, so
    /// a button held at that moment does not stay down on the console forever.
    func releaseAll()
}

/// Implement this to drive a console from your own hardware.
///
/// A source is handed a live controller when a session comes up and told when it goes away. It
/// does not need to know anything about the protocol, and it should not hold the controller past
/// `remotePlayDidDisconnect` — the session behind it is gone.
///
/// ```swift
/// final class MyDeviceSource: RemotePlayInputSource {
///     private weak var input: RemotePlayControllerInput?
///
///     func remotePlayDidConnect(_ input: RemotePlayControllerInput) { self.input = input }
///     func remotePlayDidDisconnect() { self.input = nil }
///
///     /// Called from your own device's callback, on whatever thread it arrives on.
///     func deviceDidReport(_ reading: MyReading) {
///         input?.setStick(.left, x: reading.x, y: reading.y)
///         if reading.selected { input?.press(.cross) } else { input?.release(.cross) }
///     }
/// }
/// ```
protocol RemotePlayInputSource: AnyObject {
    func remotePlayDidConnect(_ input: RemotePlayControllerInput)
    func remotePlayDidDisconnect()
}

/// Binds a source to the live controller, tagging everything it sends so it merges with the other
/// sources rather than fighting them.
///
/// Sources are deliberately kept apart: a button is held while *any* source holds it, and a stick
/// follows whichever is pushed furthest. Two people, or a device and a pad, can drive at once and
/// neither cancels the other's held button.
final class RemotePlayControllerBinding: RemotePlayControllerInput {
    private weak var controller: RPController?
    private let source: RPInputSource

    init(controller: RPController, source: RPInputSource) {
        self.controller = controller
        self.source = source
    }

    func press(_ button: RPTakion.Button) { controller?.press(button, from: source) }

    func release(_ button: RPTakion.Button) { controller?.release(button, from: source) }

    func setStick(_ stick: RPController.Stick, x: Double, y: Double) {
        controller?.setStick(stick, x: x, y: y, from: source)
    }

    func setTrigger(_ trigger: RPTakion.Button, value: UInt8) {
        controller?.setTrigger(trigger, value: value, from: source)
    }

    func releaseAll() { controller?.releaseAll(from: source) }
}
