import Foundation

/// Where a piece of input came from. The console sees one controller, so several sources are
/// merged rather than fighting: a button is held while *any* source holds it, and a stick follows
/// whichever source is pushed furthest from centre.
///
/// `custom` is yours — whatever you are building this for. `gamepad` is the physical controller
/// support that ships with the example, kept separate so the two can be used at once and neither
/// can cancel a button the other is holding.
enum RPInputSource: String, CaseIterable, Hashable {
    case custom
    case gamepad
}

/// Virtual DualShock state fed to a ready `RPStream`. Button events go out immediately; stick
/// state is change-gated and coalesced so a continuous source — head tracking, a sensor read at
/// hundreds of hertz — can't flood the console.
final class RPController {
    static let maxBufferedEvents = 5
    static let stickSendInterval: TimeInterval = 1.0 / 60.0

    private weak var stream: RPStream?
    private let queue: DispatchQueue
    private var eventSequence: UInt16 = 0
    private var stateSequence: UInt16 = 0
    /// Most recent events first, oldest evicted (the packet carries a short history).
    private var eventBuffer: [[UInt8]] = []
    /// Which sources hold each button. A button is down while this set is non-empty, so one source
    /// releasing never cancels another that is still holding it.
    private var holders: [RPTakion.Button: Set<RPInputSource>] = [:]
    /// Analog trigger pressure per source; the console is sent the firmest press.
    private var triggerValues: [RPTakion.Button: [RPInputSource: UInt8]] = [:]
    private var sentTriggers: [RPTakion.Button: UInt8] = [:]
    /// Per-source stick positions, merged on send.
    private var stickValues: [Stick: [RPInputSource: StickValue]] = [:]
    private var lastSentSticks = RPTakion.StickState()
    private var stickSendScheduled = false
    private var tapWorkItems: [TapKey: DispatchWorkItem] = [:]
    /// Pointer id in flight per source, and the next id to hand out. The console tracks a touch by
    /// its id, so an up must carry the same id the down did.
    private var touchPointers: [RPInputSource: UInt8] = [:]
    private var touchPositions: [RPInputSource: TouchPoint] = [:]
    private var nextPointerID: UInt8 = 0

    private struct TapKey: Hashable {
        let button: RPTakion.Button
        let source: RPInputSource
    }

    private struct StickValue {
        let x: Int16
        let y: Int16
        var magnitude: Double { (Double(x) * Double(x) + Double(y) * Double(y)).squareRoot() }
    }

    init(stream: RPStream) {
        self.stream = stream
        self.queue = stream.queue
    }

    // MARK: - Buttons

    func press(_ button: RPTakion.Button, from source: RPInputSource = .custom) {
        queue.async {
            self.cancelTap(button, source)
            self.setHeld(button, by: source, held: true)
        }
    }

    func release(_ button: RPTakion.Button, from source: RPInputSource = .custom) {
        queue.async {
            self.cancelTap(button, source)
            self.applyTrigger(button, value: 0, from: source)
            self.setHeld(button, by: source, held: false)
        }
    }

    /// Press then release after `holdSeconds`.
    func tap(
        _ button: RPTakion.Button, holdSeconds: TimeInterval = 0.1,
        from source: RPInputSource = .custom
    ) {
        queue.async {
            self.cancelTap(button, source)
            self.setHeld(button, by: source, held: true)
            let key = TapKey(button: button, source: source)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tapWorkItems[key] = nil
                self.setHeld(button, by: source, held: false)
            }
            self.tapWorkItems[key] = work
            self.queue.asyncAfter(deadline: .now() + holdSeconds, execute: work)
        }
    }

    /// Analog L2/R2 pressure 0–255 for one source; the console is sent the firmest press.
    func setTrigger(
        _ button: RPTakion.Button, value: UInt8, from source: RPInputSource = .custom
    ) {
        guard button.isAnalogTrigger else { return }
        queue.async { self.applyTrigger(button, value: value, from: source) }
    }

    /// Release everything one source holds and centre its sticks, leaving other sources alone.
    func releaseAll(from source: RPInputSource = .custom) {
        queue.async {
            for key in self.tapWorkItems.keys where key.source == source {
                self.tapWorkItems[key]?.cancel()
                self.tapWorkItems[key] = nil
            }
            for (button, sources) in self.holders where sources.contains(source) {
                self.setHeld(button, by: source, held: false)
            }
            for button in Array(self.triggerValues.keys) {
                self.applyTrigger(button, value: 0, from: source)
            }
            self.applyTouch(nil, from: source)
            for stick in [Stick.left, .right] {
                self.stickValues[stick]?[source] = nil
            }
            self.scheduleStickSend()
        }
    }

    /// Release everything, from every source.
    func releaseEverything() {
        for source in RPInputSource.allCases { releaseAll(from: source) }
    }

    /// Which sources are currently holding a button. Diagnostic and test aid.
    func sourcesHolding(_ button: RPTakion.Button) -> Set<RPInputSource> {
        queue.sync { holders[button] ?? [] }
    }

    private func cancelTap(_ button: RPTakion.Button, _ source: RPInputSource) {
        let key = TapKey(button: button, source: source)
        tapWorkItems[key]?.cancel()
        tapWorkItems[key] = nil
    }

    /// Update one source's hold; emit an event only when the merged state actually changes.
    private func setHeld(_ button: RPTakion.Button, by source: RPInputSource, held: Bool) {
        var sources = holders[button] ?? []
        let wasHeld = !sources.isEmpty
        if held { sources.insert(source) } else { sources.remove(source) }
        holders[button] = sources.isEmpty ? nil : sources
        let isHeld = !sources.isEmpty
        guard wasHeld != isHeld else { return }
        enqueue(button.event(pressed: isHeld))
    }

    /// Must be called on `queue`.
    private func applyTrigger(_ button: RPTakion.Button, value: UInt8, from source: RPInputSource) {
        guard button.isAnalogTrigger else { return }
        var perSource = triggerValues[button] ?? [:]
        if value == 0 { perSource[source] = nil } else { perSource[source] = value }
        triggerValues[button] = perSource.isEmpty ? nil : perSource
        let merged = perSource.values.max() ?? 0
        guard sentTriggers[button] != merged else { return }
        sentTriggers[button] = merged
        // A trigger back at rest is a plain release, so the console clears the button too.
        enqueue(merged == 0 ? button.event(pressed: false) : button.triggerEvent(value: merged))
    }

    private func enqueue(_ event: [UInt8]) {
        eventBuffer.insert(event, at: 0)
        if eventBuffer.count > RPController.maxBufferedEvents { eventBuffer.removeLast() }
        guard let stream, stream.state == .ready else { return }
        stream.sendFeedbackEvent(sequence: eventSequence, events: eventBuffer.flatMap { $0 })
        eventSequence &+= 1
    }

    // MARK: - Touchpad

    /// A point on the console's virtual touchpad.
    struct TouchPoint: Equatable {
        var x: Int
        var y: Int
    }

    /// Place or move this source's finger; nil lifts it. One finger per source, which is what both
    /// callers need — a gesture source presses one half at a time, and a physical pad forwards its
    /// first finger.
    func setTouch(_ point: TouchPoint?, from source: RPInputSource = .custom) {
        queue.async { self.applyTouch(point, from: source) }
    }

    /// Press one half of the touchpad: a real finger down at that half's coordinates, plus the
    /// click. The console has no separate left/right button — games distinguish the halves by
    /// where the finger is when the pad is clicked.
    func pressTouch(_ zone: RPTakion.Touchpad.Zone, from source: RPInputSource = .custom) {
        queue.async {
            self.cancelTouchTap(source)
            self.applyTouch(TouchPoint(x: zone.point.x, y: zone.point.y), from: source)
            self.setHeld(.touchpad, by: source, held: true)
        }
    }

    func releaseTouch(_ zone: RPTakion.Touchpad.Zone, from source: RPInputSource = .custom) {
        queue.async {
            self.cancelTouchTap(source)
            self.applyTouch(nil, from: source)
            self.setHeld(.touchpad, by: source, held: false)
        }
    }

    func tapTouch(
        _ zone: RPTakion.Touchpad.Zone, holdSeconds: TimeInterval = 0.1,
        from source: RPInputSource = .custom
    ) {
        queue.async {
            self.cancelTouchTap(source)
            self.applyTouch(TouchPoint(x: zone.point.x, y: zone.point.y), from: source)
            self.setHeld(.touchpad, by: source, held: true)
            let key = TapKey(button: .touchpad, source: source)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.tapWorkItems[key] = nil
                self.applyTouch(nil, from: source)
                self.setHeld(.touchpad, by: source, held: false)
            }
            self.tapWorkItems[key] = work
            self.queue.asyncAfter(deadline: .now() + holdSeconds, execute: work)
        }
    }

    /// Where a source's finger currently is, if any. Diagnostic and test aid.
    func touchPoint(from source: RPInputSource) -> TouchPoint? {
        queue.sync { touchPositions[source] }
    }

    private func cancelTouchTap(_ source: RPInputSource) {
        let key = TapKey(button: .touchpad, source: source)
        tapWorkItems[key]?.cancel()
        tapWorkItems[key] = nil
    }

    /// Must be called on `queue`. A move re-sends a down event with the *same* pointer id — the
    /// console tracks a finger by its id, so a lift carrying a different one strands the touch.
    private func applyTouch(_ point: TouchPoint?, from source: RPInputSource) {
        guard let point else {
            guard let pointer = touchPointers.removeValue(forKey: source) else { return }
            let last = touchPositions.removeValue(forKey: source) ?? TouchPoint(x: 0, y: 0)
            enqueue(
                RPTakion.touchEvent(pointerID: pointer, x: last.x, y: last.y, down: false))
            return
        }
        let pointer: UInt8
        if let existing = touchPointers[source] {
            guard touchPositions[source] != point else { return }
            pointer = existing
        } else {
            pointer = nextPointerID
            nextPointerID = (nextPointerID &+ 1) & 0x7F
            touchPointers[source] = pointer
        }
        touchPositions[source] = point
        enqueue(RPTakion.touchEvent(pointerID: pointer, x: point.x, y: point.y, down: true))
    }

    // MARK: - Sticks

    enum Stick: Hashable { case left, right }

    /// Axes in -1...1; x right positive, y down positive (the console's convention).
    func setStick(_ stick: Stick, x: Double, y: Double, from source: RPInputSource = .custom) {
        let vx = RPTakion.stickValue(x)
        let vy = RPTakion.stickValue(y)
        queue.async {
            var perSource = self.stickValues[stick] ?? [:]
            if vx == 0 && vy == 0 {
                perSource[source] = nil
            } else {
                perSource[source] = StickValue(x: vx, y: vy)
            }
            self.stickValues[stick] = perSource.isEmpty ? nil : perSource
            self.scheduleStickSend()
        }
    }

    func centerStick(_ stick: Stick, from source: RPInputSource = .custom) {
        setStick(stick, x: 0, y: 0, from: source)
    }

    /// The merged position of one stick: whichever source is pushed furthest from centre wins, so
    /// a source resting at centre never cancels one being used.
    private func mergedStick(_ stick: Stick) -> StickValue {
        guard let perSource = stickValues[stick], !perSource.isEmpty else {
            return StickValue(x: 0, y: 0)
        }
        var best = StickValue(x: 0, y: 0)
        var bestMagnitude = -1.0
        // Iterate in a fixed order so ties don't depend on dictionary ordering.
        for source in RPInputSource.allCases {
            guard let value = perSource[source] else { continue }
            if value.magnitude > bestMagnitude {
                bestMagnitude = value.magnitude
                best = value
            }
        }
        return best
    }

    private func scheduleStickSend() {
        guard !stickSendScheduled else { return }
        stickSendScheduled = true
        queue.asyncAfter(deadline: .now() + RPController.stickSendInterval) { [weak self] in
            guard let self else { return }
            self.stickSendScheduled = false
            self.flushSticks()
        }
    }

    private func flushSticks() {
        let left = mergedStick(.left)
        let right = mergedStick(.right)
        let merged = RPTakion.StickState(
            leftX: left.x, leftY: left.y, rightX: right.x, rightY: right.y)
        guard merged != lastSentSticks, let stream, stream.state == .ready else { return }
        lastSentSticks = merged
        stream.sendFeedbackState(sequence: stateSequence, sticks: merged)
        stateSequence &+= 1
    }
}
