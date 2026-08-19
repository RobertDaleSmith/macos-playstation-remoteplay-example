import Combine
import Foundation
import GameController

/// Feeds a physical controller attached to this Mac — a DualSense, DualShock 4, Xbox pad, anything
/// the GameController framework recognises — into the same virtual controller your own
/// input source drives.
///
/// Both are merged by `RPController`: a button is held while either source holds it, and a stick
/// follows whichever is pushed furthest. So a custom input source can play alongside someone on
/// a pad, or lean on a pad for the axes it cannot reach while keeping its own buttons.
@MainActor
final class RPGamepadSource: ObservableObject {
    /// Name of the attached controller, if any. Drives the UI.
    @Published private(set) var connectedName: String?
    @Published private(set) var isForwarding = false

    private weak var controller: RPController?
    private var observers: [NSObjectProtocol] = []
    private var gamepad: GCController?
    /// Reads Sony pads as raw HID, which is the only way to get the PS button and touchpad click.
    private let hid = RPDualSenseHID()
    /// True while HID owns the pad; the GameController path stands down to avoid double input.
    @Published private(set) var usingRawHID = false
    /// Live decode of the Sony pad's report, shown in Settings while one is attached.
    @Published private(set) var padDiagnostic: String?
    /// Buttons currently held, so a disconnect can release them rather than leaving them stuck.
    private var held: Set<RPTakion.Button> = []

    /// Every mappable digital button. Triggers are analog and handled separately. Some inputs are
    /// optional on `GCExtendedGamepad` and some aren't, so these are read through closures rather
    /// than a key-path array.
    private static let buttonMap:
        [(
            read: (GCExtendedGamepad) -> GCControllerButtonInput?,
            button: RPTakion.Button
        )] = [
            ({ $0.buttonA }, .cross), ({ $0.buttonB }, .circle),
            ({ $0.buttonX }, .square), ({ $0.buttonY }, .triangle),
            ({ $0.leftShoulder }, .l1), ({ $0.rightShoulder }, .r1),
            ({ $0.leftThumbstickButton }, .l3), ({ $0.rightThumbstickButton }, .r3),
            ({ $0.buttonOptions }, .share), ({ $0.buttonMenu }, .options), ({ $0.buttonHome }, .ps),
        ]

    init() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.attach(note.object as? GCController) }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.detach(note.object as? GCController) }
            })
        GCController.startWirelessControllerDiscovery()
        attach(GCController.controllers().first)

        hid.onDeviceChange = { [weak self] name in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.usingRawHID = name != nil
                if let name {
                    // Prefer HID: GameController reserves the PS button.
                    self.connectedName = name
                    self.gamepad?.extendedGamepad?.valueChangedHandler = nil
                } else if let existing = self.gamepad {
                    self.connectedName = existing.vendorName ?? "Game Controller"
                    self.bind()
                } else {
                    self.connectedName = nil
                }
                self.isForwarding = self.controller != nil && self.connectedName != nil
            }
        }
        hid.onDiagnostic = { [weak self] text in
            MainActor.assumeIsolated { self?.padDiagnostic = text }
        }
        hid.start()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Start forwarding into `controller`; pass nil when the session ends.
    func forward(to controller: RPController?) {
        self.controller = controller
        isForwarding = controller != nil && connectedName != nil
        if controller == nil { releaseHeld() }
        hid.forward(to: controller)
        bind()
    }

    // MARK: - Connection

    private func attach(_ candidate: GCController?) {
        guard let candidate, candidate.extendedGamepad != nil else { return }
        gamepad = candidate
        if usingRawHID { return }  // HID already owns this pad
        connectedName = candidate.vendorName ?? "Game Controller"
        isForwarding = controller != nil
        rpLogger.info("Gamepad attached: \(candidate.vendorName ?? "unknown")")
        bind()
    }

    private func detach(_ candidate: GCController?) {
        guard candidate === gamepad || candidate == nil else { return }
        releaseHeld()
        gamepad?.extendedGamepad?.valueChangedHandler = nil
        gamepad = nil
        connectedName = nil
        isForwarding = false
        padDiagnostic = nil
        rpLogger.info("Gamepad detached")
    }

    /// Release anything the pad was holding so a disconnect mid-press doesn't stick on the console.
    private func releaseHeld() {
        guard let controller else {
            held.removeAll()
            return
        }
        controller.releaseAll(from: .gamepad)
        held.removeAll()
    }

    // MARK: - Input

    private func bind() {
        guard !usingRawHID else { return }
        guard let extended = gamepad?.extendedGamepad else { return }
        guard controller != nil else {
            extended.valueChangedHandler = nil
            return
        }
        extended.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated { self?.handle(pad) }
        }
    }

    private func handle(_ pad: GCExtendedGamepad) {
        guard let controller else { return }

        for entry in Self.buttonMap {
            guard let input = entry.read(pad) else { continue }
            update(entry.button, pressed: input.isPressed, on: controller)
        }
        // The d-pad is four buttons on the wire.
        update(.up, pressed: pad.dpad.up.isPressed, on: controller)
        update(.down, pressed: pad.dpad.down.isPressed, on: controller)
        update(.left, pressed: pad.dpad.left.isPressed, on: controller)
        update(.right, pressed: pad.dpad.right.isPressed, on: controller)
        // DualSense/DS4 touchpad click, where the framework exposes it.
        if let touchpad = pad.controller?.physicalInputProfile.buttons["Touchpad Button"] {
            update(.touchpad, pressed: touchpad.isPressed, on: controller)
        }

        controller.setTrigger(.l2, value: Self.triggerValue(pad.leftTrigger), from: .gamepad)
        controller.setTrigger(.r2, value: Self.triggerValue(pad.rightTrigger), from: .gamepad)

        // GameController reports Y up-positive; the console wants down-positive.
        controller.setStick(
            .left, x: Double(pad.leftThumbstick.xAxis.value),
            y: Double(-pad.leftThumbstick.yAxis.value), from: .gamepad)
        controller.setStick(
            .right, x: Double(pad.rightThumbstick.xAxis.value),
            y: Double(-pad.rightThumbstick.yAxis.value), from: .gamepad)
    }

    private func update(_ button: RPTakion.Button, pressed: Bool, on controller: RPController) {
        let wasHeld = held.contains(button)
        guard wasHeld != pressed else { return }
        if pressed {
            held.insert(button)
            controller.press(button, from: .gamepad)
        } else {
            held.remove(button)
            controller.release(button, from: .gamepad)
        }
    }

    static func triggerValue(_ input: GCControllerButtonInput) -> UInt8 {
        UInt8(clamping: Int(input.value * 255))
    }
}
