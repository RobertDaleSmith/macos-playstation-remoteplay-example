#if os(macOS)

    import AppKit
    import Foundation

    /// Keyboard control for the video window.
    ///
    /// The window is where you are already looking when playing on the laptop, so it is the natural
    /// place to take input from. This maps keys to controller buttons only while that window has
    /// focus, so normal typing anywhere else in the app is untouched.
    enum RPKeyboardMap {
        /// macOS virtual key codes, which are layout-independent — the arrow keys and Return sit at
        /// the same codes regardless of the keyboard layout, where characters do not.
        enum Key {
            static let upArrow: UInt16 = 126
            static let downArrow: UInt16 = 125
            static let leftArrow: UInt16 = 123
            static let rightArrow: UInt16 = 124
            static let returnKey: UInt16 = 36
            static let keypadEnter: UInt16 = 76
            static let escape: UInt16 = 53
            static let delete: UInt16 = 51
            static let tab: UInt16 = 48
            static let space: UInt16 = 49
            static let letterZ: UInt16 = 6
            static let letterX: UInt16 = 7
            static let letterC: UInt16 = 8
            static let letterV: UInt16 = 9
            static let letterQ: UInt16 = 12
            static let letterE: UInt16 = 14
            static let digit1: UInt16 = 18
            static let digit2: UInt16 = 19
        }

        /// The default layout. Arrows and Return are what someone reaches for without being told;
        /// the letter keys follow the usual emulator arrangement around the left hand.
        static let buttons: [UInt16: RPTakion.Button] = [
            Key.upArrow: .up, Key.downArrow: .down, Key.leftArrow: .left, Key.rightArrow: .right,
            Key.returnKey: .cross, Key.keypadEnter: .cross, Key.letterX: .cross,
            Key.delete: .circle, Key.letterC: .circle,
            Key.letterZ: .square, Key.letterV: .triangle,
            Key.escape: .ps, Key.tab: .options, Key.space: .touchpad,
            Key.letterQ: .l1, Key.letterE: .r1,
            Key.digit1: .l2, Key.digit2: .r2,
        ]

        static func button(for keyCode: UInt16) -> RPTakion.Button? { buttons[keyCode] }

        /// Human-readable summary for the Settings help, generated from the map itself so it cannot
        /// drift from what the keys actually do.
        static let summary =
            "Arrows = D-pad · Return or X = Cross · Delete or C = Circle · Z = Square · V = Triangle · Esc = PS · Tab = Options · Space = Touchpad · Q/E = L1/R1 · 1/2 = L2/R2"
    }

#endif
