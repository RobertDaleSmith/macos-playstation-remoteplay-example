import Foundation
import IOKit.hid

/// Reads a DualSense (or DualShock 4) directly as a HID device.
///
/// Apple's GameController framework reserves the PS/Home button and doesn't hand it to apps, so a
/// pad read through it can never send PS. SDL — which the Python bridge uses, and which does
/// deliver that button — reads the pad as raw HID instead. This does the same, which also exposes
/// the touchpad click and (later) the gyro/accel block.
///
/// The report layouts differ by transport — see `layout(reportID:count:)`.
final class RPDualSenseHID {
    struct Supported {
        let vendor: Int
        let product: Int
        let name: String
    }

    /// Sony pads whose report layout this understands.
    static let supported = [
        Supported(vendor: 0x054C, product: 0x0CE6, name: "DualSense"),
        Supported(vendor: 0x054C, product: 0x0DF2, name: "DualSense Edge"),
        Supported(vendor: 0x054C, product: 0x09CC, name: "DualShock 4"),
        Supported(vendor: 0x054C, product: 0x05C4, name: "DualShock 4"),
    ]

    /// Parsed controller state; only what the Remote Play feedback packets can carry.
    struct State: Equatable {
        var buttons: Set<RPTakion.Button> = []
        var leftX = 0.0
        var leftY = 0.0
        var rightX = 0.0
        var rightY = 0.0
        var l2: UInt8 = 0
        var r2: UInt8 = 0
        /// First finger on the pad's own touchpad, in its native resolution.
        var touch: Touch?
    }

    private let queue = DispatchQueue(label: "com.example.psremoteplay.hid")
    private var manager: IOHIDManager?
    /// IOKit keeps this pointer for the life of the registration, so it must be a stable
    /// allocation — handing it `&someArray` yields a pointer valid only during that call.
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
    private static let reportBufferSize = 128
    private var sawFirstReport = false
    private var lastDiagnosticSignature = ""
    private var previous = State()
    /// The attached pad's USB product id — DS4 and DualSense order their report fields
    /// differently, so the layout can't be chosen from the report alone.
    private var product: Int = 0
    private var controller: RPController?

    /// Called on the main queue with a live summary of the report being parsed. A touchpad that
    /// doesn't reach the console could be the offset, the click bit, or the send path, and those
    /// are indistinguishable without seeing the decode.
    var onDiagnostic: ((String) -> Void)?

    /// Called on the main queue when a pad appears or disappears.
    var onDeviceChange: ((String?) -> Void)?
    private(set) var deviceName: String?

    // MARK: - Lifecycle

    func start() {
        queue.async { self.startLocked() }
    }

    func stop() {
        queue.async {
            self.releaseHeld()
            if let manager = self.manager {
                IOHIDManagerUnscheduleFromRunLoop(
                    manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            self.manager = nil
            self.setDeviceName(nil)
        }
    }

    /// Forward into `controller`; pass nil to stop (releases anything the pad was holding).
    func forward(to controller: RPController?) {
        queue.async {
            if controller == nil { self.releaseHeld() }
            self.controller = controller
        }
    }

    private func startLocked() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = RPDualSenseHID.supported.map {
            [kIOHIDVendorIDKey: $0.vendor, kIOHIDProductIDKey: $0.product] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<RPDualSenseHID>.fromOpaque(context).takeUnretainedValue()
                    .deviceAttached(device)
            }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, _ in
                guard let context else { return }
                Unmanaged<RPDualSenseHID>.fromOpaque(context).takeUnretainedValue().deviceRemoved()
            }, context)

        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if opened != kIOReturnSuccess {
            // Usually the sandbox: a wired pad needs com.apple.security.device.usb.
            rpLogger.error("HID manager could not open (0x\(String(opened, radix: 16)))")
        }
        self.manager = manager
    }

    private func deviceAttached(_ device: IOHIDDevice) {
        let product =
            (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String)
            ?? "Sony Controller"
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        queue.async { self.product = productID }
        rpLogger.info("HID pad attached: \(product)")
        IOHIDDeviceRegisterInputReportCallback(
            device, reportBuffer, RPDualSenseHID.reportBufferSize,
            { context, _, _, _, reportID, report, length in
                guard let context, length > 0 else { return }
                let source = Unmanaged<RPDualSenseHID>.fromOpaque(context).takeUnretainedValue()
                let bytes = [UInt8](UnsafeBufferPointer(start: report, count: length))
                source.handleReport(id: reportID, bytes: bytes)
            }, Unmanaged.passUnretained(self).toOpaque())
        setDeviceName(product)
    }

    deinit { reportBuffer.deallocate() }

    private func deviceRemoved() {
        queue.async {
            self.releaseHeld()
            self.setDeviceName(nil)
        }
        rpLogger.info("HID pad removed")
    }

    private func setDeviceName(_ name: String?) {
        deviceName = name
        DispatchQueue.main.async { self.onDeviceChange?(name) }
    }

    private func releaseHeld() {
        controller?.releaseAll(from: .gamepad)
        previous = State()
    }

    // MARK: - Reports

    private func handleReport(id: UInt32, bytes: [UInt8]) {
        queue.async {
            if !self.sawFirstReport {
                self.sawFirstReport = true
                rpLogger.info(
                    "HID reports flowing: id 0x\(String(id, radix: 16)), \(bytes.count) bytes")
            }
            guard
                let state = RPDualSenseHID.parse(reportID: id, bytes: bytes, product: self.product)
            else {
                rpLogger.debug("HID report id 0x\(String(id, radix: 16)) not understood")
                return
            }
            self.report(state, id: id, length: bytes.count)
            self.apply(state)
        }
    }

    /// Publish the decode whenever the touch or click changes, so a press is visible even if
    /// nothing downstream reacts to it.
    private func report(_ state: State, id: UInt32, length: Int) {
        let click = state.buttons.contains(.touchpad)
        let signature = "\(click)-\(String(describing: state.touch))"
        guard signature != lastDiagnosticSignature else { return }
        lastDiagnosticSignature = signature
        let touchText: String
        if let touch = state.touch {
            let side = touch.x < 960 ? "LEFT" : "RIGHT"
            touchText = "finger \(touch.x),\(touch.y) (\(side))"
        } else {
            touchText = "no finger"
        }
        let offset = RPDualSenseHID.layout(reportID: id, count: length, product: product)?.touch
        let text =
            "report 0x\(String(id, radix: 16)) \(length)B · touch@\(offset.map(String.init) ?? "none") · click \(click ? "DOWN" : "up") · \(touchText)"
        DispatchQueue.main.async { self.onDiagnostic?(text) }
    }

    /// Byte offsets of the fields we use, for one report layout.
    struct Layout {
        let axes: Int  // LX, LY, RX, RY
        let buttons: Int  // b0 (hat + face), b1, b2
        let triggers: Int  // L2, R2
        let minimumLength: Int
        /// Offset of the first finger's status byte; the three position bytes follow it. Derived
        /// from the joypad-os report structs (`sony_ds4.h`, `sony_ds5.h`) by walking the fields
        /// ahead of `tpad_f1_count`. nil when the report shape doesn't carry touch data.
        var touch: Int?
    }

    /// One finger as the pad reports it.
    struct Touch: Equatable {
        var x: Int
        var y: Int
    }

    /// Rescale a finger from the pad's own touchpad onto the console's. A DualSense pad is taller
    /// than the DualShock 4 the Remote Play client emulates, so passing raw coordinates through
    /// would squash everything into the top of the console's pad.
    static func consoleTouch(_ touch: Touch?, product: Int) -> RPController.TouchPoint? {
        guard let touch else { return nil }
        let size =
            dualShock4ProductIDs.contains(product) ? dualShock4TouchSize : dualSenseTouchSize
        let x = Int(
            (Double(touch.x) / Double(size.width)) * Double(RPTakion.Touchpad.width))
        let y = Int(
            (Double(touch.y) / Double(size.height)) * Double(RPTakion.Touchpad.height))
        return RPController.TouchPoint(
            x: max(0, min(RPTakion.Touchpad.width - 1, x)),
            y: max(0, min(RPTakion.Touchpad.height - 1, y)))
    }

    /// Physical touchpad resolution, used to rescale onto the console's virtual pad.
    static let dualShock4TouchSize = (width: 1920, height: 942)
    static let dualSenseTouchSize = (width: 1920, height: 1080)

    /// Decode one finger. Sony packs a 12-bit x and a 12-bit y across three bytes, and the top bit
    /// of the status byte is *inactive* — set means no finger, which is the opposite of how it
    /// reads.
    static func touch(in bytes: [UInt8], at offset: Int) -> Touch? {
        guard offset + 3 < bytes.count else { return nil }
        guard bytes[offset] & 0x80 == 0 else { return nil }
        let b0 = Int(bytes[offset + 1])
        let b1 = Int(bytes[offset + 2])
        let b2 = Int(bytes[offset + 3])
        return Touch(x: b0 | ((b1 & 0x0F) << 8), y: ((b1 & 0xF0) >> 4) | (b2 << 4))
    }

    /// The pad speaks three different report shapes, and they don't share a field order.
    ///
    /// Observed from a DualSense on Bluetooth (`01 85 82 7e 78 08 00 30 00 00` at rest): the id is
    /// byte 0, axes follow, and the analog triggers are at the *end* — not after the axes as they
    /// are over USB. Reading the USB layout on this report turns axis noise into button presses.
    /// Product ids whose reports put the triggers after the buttons, DS4-style.
    static let dualShock4ProductIDs: Set<Int> = [0x09CC, 0x05C4]

    /// The pad speaks several report shapes and they don't share a field order, so the layout
    /// can't be inferred from the report alone — a DS4 and a DualSense both send report 0x01.
    ///
    /// Field orders are taken from joypad-os, which implements both pads as host input
    /// (`sony_ds4.h`, `sony_ds5.h`, `ds4_bt.c`), and confirmed against a DualSense capture:
    ///
    /// - **DS4** (USB `0x01`, BT `0x11` with a 2-byte header): axes, buttons, then triggers.
    /// - **DualSense** (USB `0x01`, BT `0x31` with a 1-byte header): axes, triggers, seq, buttons.
    /// - **DualSense over BT in compatibility mode** (`0x01`, ~10 bytes): the DS4 order.
    ///
    /// Offsets below include the report id, which IOKit leaves as byte 0 on these devices.
    static func layout(reportID: UInt32, count: Int, product: Int = 0) -> Layout? {
        let isDualShock4 = dualShock4ProductIDs.contains(product)
        switch reportID {
        case 0x01 where count <= 16:
            // DualSense over BT in compatibility mode: DS4 order, and no touch data.
            return Layout(axes: 1, buttons: 5, triggers: 8, minimumLength: 10, touch: nil)
        case 0x01 where isDualShock4:
            // DS4 order: triggers trail the buttons.
            return Layout(axes: 1, buttons: 5, triggers: 8, minimumLength: 10, touch: 35)
        case 0x01:
            // DualSense full USB report.
            return Layout(axes: 1, buttons: 8, triggers: 5, minimumLength: 11, touch: 33)
        case 0x11:
            // DS4 over Bluetooth: the USB report behind a 2-byte header.
            return Layout(axes: 3, buttons: 7, triggers: 10, minimumLength: 12, touch: 37)
        case 0x31:
            // DualSense over Bluetooth: the USB report behind a 1-byte header.
            return Layout(axes: 2, buttons: 9, triggers: 6, minimumLength: 12, touch: 34)
        default:
            return nil
        }
    }

    /// Turn a raw input report into controller state. Returns nil for reports we don't understand.
    static func parse(reportID: UInt32, bytes: [UInt8], product: Int = 0) -> State? {
        guard let layout = layout(reportID: reportID, count: bytes.count, product: product),
            bytes.count >= layout.minimumLength
        else { return nil }

        func axis(_ raw: UInt8) -> Double {
            // 0…255 with 128 centred, to -1…1.
            (Double(raw) - 127.5) / 127.5
        }

        var state = State()
        state.leftX = axis(bytes[layout.axes])
        state.leftY = axis(bytes[layout.axes + 1])
        state.rightX = axis(bytes[layout.axes + 2])
        state.rightY = axis(bytes[layout.axes + 3])
        state.l2 = bytes[layout.triggers]
        state.r2 = bytes[layout.triggers + 1]

        let b0 = bytes[layout.buttons]
        let b1 = bytes[layout.buttons + 1]
        let b2 = bytes[layout.buttons + 2]

        // Low nibble of b0 is a hat switch: 0 = north, going clockwise, 8 = centred.
        switch b0 & 0x0F {
        case 0: state.buttons.formUnion([.up])
        case 1: state.buttons.formUnion([.up, .right])
        case 2: state.buttons.formUnion([.right])
        case 3: state.buttons.formUnion([.right, .down])
        case 4: state.buttons.formUnion([.down])
        case 5: state.buttons.formUnion([.down, .left])
        case 6: state.buttons.formUnion([.left])
        case 7: state.buttons.formUnion([.left, .up])
        default: break
        }
        if b0 & 0x10 != 0 { state.buttons.insert(.square) }
        if b0 & 0x20 != 0 { state.buttons.insert(.cross) }
        if b0 & 0x40 != 0 { state.buttons.insert(.circle) }
        if b0 & 0x80 != 0 { state.buttons.insert(.triangle) }

        if b1 & 0x01 != 0 { state.buttons.insert(.l1) }
        if b1 & 0x02 != 0 { state.buttons.insert(.r1) }
        if b1 & 0x10 != 0 { state.buttons.insert(.share) }
        if b1 & 0x20 != 0 { state.buttons.insert(.options) }
        if b1 & 0x40 != 0 { state.buttons.insert(.l3) }
        if b1 & 0x80 != 0 { state.buttons.insert(.r3) }

        // The two GameController won't give us. The upper bits of b2 are a frame counter, so mask
        // them off rather than treating every increment as a button.
        if b2 & 0x01 != 0 { state.buttons.insert(.ps) }
        if b2 & 0x02 != 0 { state.buttons.insert(.touchpad) }

        if let offset = layout.touch {
            state.touch = RPDualSenseHID.touch(in: bytes, at: offset)
        }

        return state
    }

    private func apply(_ state: State) {
        guard let controller else {
            previous = state
            return
        }
        for button in state.buttons.subtracting(previous.buttons) {
            controller.press(button, from: .gamepad)
        }
        for button in previous.buttons.subtracting(state.buttons) {
            controller.release(button, from: .gamepad)
        }
        if state.l2 != previous.l2 { controller.setTrigger(.l2, value: state.l2, from: .gamepad) }
        if state.r2 != previous.r2 { controller.setTrigger(.r2, value: state.r2, from: .gamepad) }
        if state.leftX != previous.leftX || state.leftY != previous.leftY {
            controller.setStick(.left, x: state.leftX, y: state.leftY, from: .gamepad)
        }
        if state.rightX != previous.rightX || state.rightY != previous.rightY {
            controller.setStick(.right, x: state.rightX, y: state.rightY, from: .gamepad)
        }
        if state.touch != previous.touch {
            controller.setTouch(
                RPDualSenseHID.consoleTouch(state.touch, product: product), from: .gamepad)
        }
        previous = state
    }
}
