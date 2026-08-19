#if os(macOS)

    import AVFoundation
    import AppKit
    import CoreMedia

    /// A floating window showing the console's video.
    ///
    /// Deliberately a plain resizable window rather than a panel or sheet: it has to sit alongside the
    /// game and the Settings window, be draggable anywhere including onto a second display, and
    /// survive the app being used normally around it. Its frame is remembered, because a window you
    /// have to re-place every session is a window you stop opening.
    @MainActor
    final class RemotePlayVideoWindowController: NSObject, NSWindowDelegate {
        static let frameKey = "psRemotePlay.videoWindowFrame"
        static let floatKey = "psRemotePlay.videoWindowFloats"
        /// Fallback until the stream reports its real dimensions.
        static let defaultSize = NSSize(width: 960, height: 540)

        private var window: NSWindow?
        private var displayView: RPVideoLayerView?
        private var aspectRatio = NSSize(width: 16, height: 9)

        /// Called when the user closes the window, so the setting can follow.
        var onClose: (() -> Void)?

        /// Supplies a line describing the decoder's state. A window that is simply black gives
        /// the user nothing to act on, so until frames arrive it says what is actually happening.
        var statusProvider: (() -> String)?
        /// Key presses from the video window, as controller buttons. Set by whoever owns a session.
        var onButton: ((RPTakion.Button, Bool) -> Void)?
        /// The overlay's audio controls.
        var onToggleAudio: (() -> Void)?
        var onVolume: ((Float) -> Void)?
        private var statusTimer: Timer?
        /// Runs only while the window chrome is showing, to notice the pointer leaving.
        private var chromeTimer: Timer?
        private var audioState: (on: Bool, volume: Float) = (true, 1)

        var isOpen: Bool { window?.isVisible ?? false }

        /// The stored preference, for anything that needs it before a window exists.
        static var storedFloatsOnTop: Bool {
            UserDefaults.standard.object(forKey: floatKey) as? Bool ?? false
        }

        /// Off by default. A video window that covers every other window cannot be worked
        /// alongside, and this one is meant to sit next to whatever else is open.
        var floatsOnTop: Bool {
            get { UserDefaults.standard.object(forKey: Self.floatKey) as? Bool ?? false }
            set {
                UserDefaults.standard.set(newValue, forKey: Self.floatKey)
                window?.level = newValue ? .floating : .normal
            }
        }

        /// Bring the chrome back and watch for the pointer to leave.
        ///
        /// Leaving is not taken from the view's exit event: the window buttons sit above the
        /// content view, so moving onto them reads as an exit and would hide them out from under
        /// the pointer. Where the pointer actually is settles it instead, and the timer only runs
        /// while the chrome is up.
        private func revealChrome() {
            setChrome(visible: true, animated: true)
            guard chromeTimer == nil else { return }
            chromeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    guard !window.frame.contains(NSEvent.mouseLocation) else { return }
                    self.setChrome(visible: false, animated: true)
                    self.chromeTimer?.invalidate()
                    self.chromeTimer = nil
                }
            }
        }

        /// Show or hide the window buttons. With a transparent title bar over full-size content
        /// they are the only chrome left, so hiding them leaves nothing but picture — and a
        /// window pinned above everything else should not be showing a title bar it does not need.
        private func setChrome(visible: Bool, animated: Bool) {
            guard let window else { return }
            let buttons = [
                window.standardWindowButton(.closeButton),
                window.standardWindowButton(.miniaturizeButton),
                window.standardWindowButton(.zoomButton),
            ].compactMap { $0 }
            displayView?.setChrome(visible: visible, animated: animated)
            let alpha: CGFloat = visible ? 1 : 0
            guard animated else {
                for button in buttons { button.alphaValue = alpha }
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                for button in buttons { button.animator().alphaValue = alpha }
            }
        }

        /// Show the audio state the overlay should be reflecting. Remembered as well as applied:
        /// the settings are live before the window is ever opened, and the overlay has to open
        /// showing them rather than its defaults.
        func setAudio(on: Bool, volume: Float) {
            audioState = (on, volume)
            displayView?.setAudio(on: on, volume: volume)
        }

        func show() {
            if let window {
                window.makeKeyAndOrderFront(nil)
                // Reclaim focus for the layer view: the window may have been left with a different
                // responder, and without it no key ever reaches the controller.
                if let displayView { window.makeFirstResponder(displayView) }
                return
            }
            let view = RPVideoLayerView(frame: NSRect(origin: .zero, size: Self.defaultSize))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                styleMask: [
                    .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
                ],
                backing: .buffered, defer: false)
            window.title = "PlayStation"
            // The picture runs the full height of the window and the title bar floats over it,
            // so nothing is reserved for chrome that is usually not wanted on a video window.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = view
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.level = floatsOnTop ? .floating : .normal
            // Keep the picture's shape while dragging a corner.
            window.contentAspectRatio = aspectRatio
            window.setContentSize(Self.defaultSize)
            window.minSize = NSSize(width: 320, height: 180)
            // Drag from anywhere in the picture, not just the title bar — the title bar is a small
            // target on a window that is mostly video.
            window.isMovableByWindowBackground = true
            // Follow the app across Spaces, since it is a companion to whatever else is on screen.
            window.collectionBehavior = [.fullScreenAuxiliary, .managed]

            // A saved frame is only honoured if it is still usable. The frame is written on every
            // move and resize, so a window that was ever left degenerate — collapsed by a bad
            // resize, or on a display that is no longer attached — would otherwise restore to
            // exactly that and show nothing, outliving whatever caused it.
            if let saved = UserDefaults.standard.string(forKey: Self.frameKey),
                Self.isUsable(NSRectFromString(saved), minimum: window.minSize)
            {
                window.setFrame(NSRectFromString(saved), display: false)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.frameKey)
                window.setContentSize(Self.defaultSize)
                window.center()
            }
            view.onButton = { [weak self] button, pressed in
                self?.onButton?(button, pressed)
            }
            view.onHover = { [weak self] inside in
                guard inside else { return }
                self?.revealChrome()
            }
            view.onToggleAudio = { [weak self] in self?.onToggleAudio?() }
            view.onVolume = { [weak self] volume in self?.onVolume?(volume) }
            self.window = window
            self.displayView = view
            view.setAudio(on: audioState.on, volume: audioState.volume)
            setChrome(visible: false, animated: false)
            window.makeKeyAndOrderFront(nil)
            // After the window is key, not before: setting the first responder on a window that is
            // not yet on screen does not stick, and the view then never receives a key event.
            window.makeFirstResponder(view)

            // Poll the decoder so the window can say why it is empty.
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.displayView else { return }
                    view.status = self.statusProvider?() ?? ""
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            statusTimer = timer
        }

        func close() {
            saveFrame()
            statusTimer?.invalidate()
            statusTimer = nil
            chromeTimer?.invalidate()
            chromeTimer = nil
            window?.orderOut(nil)
        }

        private(set) var enqueueCalls = 0
        private(set) var enqueueWithoutView = 0

        /// Push a decoded frame to the layer.
        func enqueue(_ sample: CMSampleBuffer) {
            enqueueCalls += 1
            guard let displayView else {
                enqueueWithoutView += 1
                return
            }
            displayView.enqueue(sample)
        }

        /// What the display layer is doing, for the diagnostics. Counts the hop into this
        /// controller as well as the layer's own, because "delivered but not enqueued" needs to
        /// distinguish a call that never arrived from one that arrived with no view behind it.
        var layerReport: String {
            let hop = "calls \(enqueueCalls) noView \(enqueueWithoutView)"
            let keys = displayView.map { "keys \($0.keyEvents)/\($0.mappedKeys)" } ?? "keys -"
            return "\(hop) · \(keys) · \(displayView?.layerReport ?? "no view")"
        }

        /// Resize to the stream's real shape once it is known, keeping the current width.
        func adoptVideoSize(_ size: CGSize) {
            guard size.width > 0, size.height > 0, let window else { return }
            aspectRatio = NSSize(width: size.width, height: size.height)
            window.contentAspectRatio = aspectRatio
            // Deliberately does not resize a window restored from a saved frame. Doing so was
            // introduced alongside the padding trim and the picture went blank in the same step;
            // resizing a window out from under a display layer is not worth a cosmetic gain.
            guard UserDefaults.standard.string(forKey: Self.frameKey) == nil else { return }
            let width = window.contentLayoutRect.width
            window.setContentSize(NSSize(width: width, height: width * size.height / size.width))
        }

        /// Big enough to show a picture, and actually on a screen that exists.
        static func isUsable(_ frame: NSRect, minimum: NSSize) -> Bool {
            guard frame.width >= minimum.width, frame.height >= minimum.height else { return false }
            return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        }

        private func saveFrame() {
            guard let window else { return }
            let frame = window.frame
            guard Self.isUsable(frame, minimum: window.minSize) else { return }
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
        }

        func windowWillClose(_ notification: Notification) {
            saveFrame()
            onClose?()
        }

        func windowDidEndLiveResize(_ notification: Notification) {
            saveFrame()
        }

        func windowDidMove(_ notification: Notification) {
            saveFrame()
        }
    }

    /// Hosts an `AVSampleBufferDisplayLayer`. Layer-backed rather than a SwiftUI view because frames
    /// arrive 30-60 times a second and should not go through the view system.
    final class RPVideoLayerView: NSView {
        private let displayLayer = AVSampleBufferDisplayLayer()
        private let statusLabel = NSTextField(labelWithString: "Waiting for video…")
        private var receivedAFrame = false
        var onButton: ((RPTakion.Button, Bool) -> Void)?
        /// True while the pointer is over the picture. Drives the window chrome.
        var onHover: ((Bool) -> Void)?
        /// The overlay bars: a title bar drawn inside the picture behind the window buttons, and
        /// a control pill along the bottom. Both are the window's own, not AppKit's, because the
        /// real title bar is transparent so that the picture can run the full height.
        private let topBar = RPTitleBarView()
        private let titleLabel = NSTextField(labelWithString: "PlayStation")
        private let controlBar = NSVisualEffectView()
        private let audioButton = NSButton()
        private let volumeSlider = NSSlider()
        private var topBarHeight: NSLayoutConstraint?
        var onToggleAudio: (() -> Void)?
        var onVolume: ((Float) -> Void)?
        private var hoverArea: NSTrackingArea?
        private(set) var keyEvents = 0
        private(set) var mappedKeys = 0

        /// Rebuilt on every geometry change: a tracking area is fixed to the rect it was made
        /// with, so a resized window would otherwise keep reporting the old bounds.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }

        override func mouseExited(with event: NSEvent) { onHover?(false) }

        // The window is only useful for playing if it can also take input.
        override var acceptsFirstResponder: Bool { true }

        // Key events stop here rather than continuing up the responder chain, which ends at
        // NSBeep for anything unhandled. Passing auto-repeat through was audible as a stream of
        // beeps for as long as a mapped key was held down, and every unmapped key beeped once.
        // While this window has focus it is a controller surface, so no keystroke is unhandled.
        // Command combinations are unaffected: those arrive as key equivalents, not key events.
        override func keyDown(with event: NSEvent) {
            keyEvents += 1
            // isARepeat is the auto-repeat the system generates while a key is held; the button is
            // already down, and re-pressing it would retrigger taps on the console.
            guard !event.isARepeat, let button = RPKeyboardMap.button(for: event.keyCode) else {
                return
            }
            mappedKeys += 1
            onButton?(button, true)
        }

        override func keyUp(with event: NSEvent) {
            guard let button = RPKeyboardMap.button(for: event.keyCode) else { return }
            onButton?(button, false)
        }

        /// Losing focus with keys held would leave them stuck down on the console.
        override func resignFirstResponder() -> Bool {
            for button in Set(RPKeyboardMap.buttons.values) { onButton?(button, false) }
            return super.resignFirstResponder()
        }
        private(set) var enqueued = 0
        private(set) var refusedWhileBusy = 0
        private(set) var flushesToResume = 0

        /// What the display layer makes of the frames, which is the only thing left once the
        /// decoder reports success and the picture is still blank.
        var layerReport: String {
            let state: String
            switch displayLayer.status {
            case .failed: state = "failed(\(displayLayer.error?.localizedDescription ?? "?"))"
            case .rendering: state = "rendering"
            case .unknown: state = "unknown"
            @unknown default: state = "?"
            }
            return
                "layer \(state) enqueued \(enqueued) busy \(refusedWhileBusy) flush \(flushesToResume)"
        }

        /// Shown until the first frame arrives. A black window tells the user nothing they can act
        /// on; the counts behind it say whether packets are arriving, parsing, or decoding.
        var status: String = "" {
            didSet {
                guard !receivedAFrame else { return }
                statusLabel.stringValue = "Waiting for video…\n\(status)"
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            // Order matters: assign the layer first, then opt into layer backing. Setting
            // wantsLayer first makes AppKit create its own layer, and the one assigned afterwards
            // is not necessarily the one that gets displayed — the sublayer renders into nothing.
            let host = CALayer()
            host.backgroundColor = NSColor.black.cgColor
            layer = host
            wantsLayer = true
            layerContentsRedrawPolicy = .duringViewResize
            displayLayer.videoGravity = .resizeAspect
            displayLayer.frame = bounds
            host.addSublayer(displayLayer)

            statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.alignment = .center
            statusLabel.maximumNumberOfLines = 0
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(statusLabel)
            NSLayoutConstraint.activate([
                statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                statusLabel.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingAnchor, constant: 12),
            ])
            buildOverlay()
        }

        private func buildOverlay() {
            for bar in [topBar, controlBar] {
                bar.material = .hudWindow
                bar.blendingMode = .withinWindow
                bar.state = .active
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.alphaValue = 0
                addSubview(bar)
            }
            controlBar.wantsLayer = true
            controlBar.layer?.cornerRadius = 10
            controlBar.layer?.masksToBounds = true

            titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
            titleLabel.textColor = .labelColor
            titleLabel.alignment = .center
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(titleLabel)

            // Neither control may take first responder: focus is what routes the keyboard to the
            // controller, and a click on the volume slider would otherwise end it.
            audioButton.isBordered = false
            audioButton.bezelStyle = .regularSquare
            audioButton.imagePosition = .imageOnly
            audioButton.refusesFirstResponder = true
            audioButton.target = self
            audioButton.action = #selector(audioButtonPressed)
            audioButton.translatesAutoresizingMaskIntoConstraints = false
            controlBar.addSubview(audioButton)

            volumeSlider.minValue = 0
            volumeSlider.maxValue = 1
            volumeSlider.doubleValue = 1
            volumeSlider.isContinuous = true
            volumeSlider.refusesFirstResponder = true
            volumeSlider.target = self
            volumeSlider.action = #selector(volumeChanged)
            volumeSlider.translatesAutoresizingMaskIntoConstraints = false
            controlBar.addSubview(volumeSlider)

            let height = topBar.heightAnchor.constraint(equalToConstant: 28)
            topBarHeight = height
            NSLayoutConstraint.activate([
                topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
                topBar.topAnchor.constraint(equalTo: topAnchor),
                height,
                titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

                controlBar.centerXAnchor.constraint(equalTo: centerXAnchor),
                controlBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
                controlBar.heightAnchor.constraint(equalToConstant: 36),
                audioButton.leadingAnchor.constraint(
                    equalTo: controlBar.leadingAnchor, constant: 12),
                audioButton.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
                audioButton.widthAnchor.constraint(equalToConstant: 20),
                volumeSlider.leadingAnchor.constraint(
                    equalTo: audioButton.trailingAnchor, constant: 10),
                volumeSlider.trailingAnchor.constraint(
                    equalTo: controlBar.trailingAnchor, constant: -14),
                volumeSlider.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
                volumeSlider.widthAnchor.constraint(equalToConstant: 90),
            ])
        }

        @objc private func audioButtonPressed() { onToggleAudio?() }

        @objc private func volumeChanged() { onVolume?(Float(volumeSlider.doubleValue)) }

        /// Reflect the audio settings the overlay is showing.
        func setAudio(on: Bool, volume: Float) {
            audioButton.image = NSImage(
                systemSymbolName: on ? "speaker.wave.2.fill" : "speaker.slash.fill",
                accessibilityDescription: on ? "Mute" : "Unmute")
            audioButton.contentTintColor = .labelColor
            volumeSlider.doubleValue = Double(volume)
            volumeSlider.isEnabled = on
        }

        /// Fade the overlay in or out with the window buttons.
        func setChrome(visible: Bool, animated: Bool) {
            let alpha: CGFloat = visible ? 1 : 0
            guard animated else {
                topBar.alphaValue = alpha
                controlBar.alphaValue = alpha
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                topBar.animator().alphaValue = alpha
                controlBar.animator().alphaValue = alpha
            }
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            displayLayer.frame = bounds
            // Match the real title bar so the window buttons sit inside the drawn one. The height
            // is not a constant across styles or displays, so it is measured rather than assumed.
            if let window, window.contentLayoutRect.height > 0 {
                let inset = bounds.height - window.contentLayoutRect.height
                if inset > 0, inset < 60 { topBarHeight?.constant = inset }
            }
        }

        func enqueue(_ sample: CMSampleBuffer) {
            // A failed layer stays failed until flushed; without this a single bad frame ends video
            // for the rest of the session.
            if displayLayer.status == .failed { displayLayer.flush() }
            if !receivedAFrame {
                receivedAFrame = true
                statusLabel.isHidden = true
            }
            // The layer stops decoding when the app is backgrounded or the window is occluded,
            // and silently ignores everything enqueued until it is flushed. Playing on the TV with
            // this window unfocused is exactly that case: frames are accepted, the status stays
            // "rendering", and nothing is ever drawn.
            if displayLayer.requiresFlushToResumeDecoding {
                flushesToResume += 1
                displayLayer.flush()
            }
            guard displayLayer.isReadyForMoreMediaData else {
                refusedWhileBusy += 1
                return
            }
            enqueued += 1
            displayLayer.enqueue(sample)
        }
    }

    /// The title bar drawn inside the picture.
    ///
    /// A real title bar drags the window and, on a double click, zooms or minimises according to
    /// the user's setting. One that only looks like a title bar should do the same, so both are
    /// forwarded here rather than left to fall through to the video.
    private final class RPTitleBarView: NSVisualEffectView {
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else {
                window?.performDrag(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.miniaturize(nil)
            case "None": break
            // "Maximize", and whatever a future system calls it: zoom is the long-standing default.
            default: window?.zoom(nil)
            }
        }

        /// The title is decoration, so the whole strip answers as one rather than the label
        /// swallowing clicks that land on the text.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let superview else { return nil }
            return bounds.contains(convert(point, from: superview)) ? self : nil
        }
    }

#endif
