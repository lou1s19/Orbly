import AppKit

/// Watches the configured dictation key (see `DictationKey`) through global and
/// local flagsChanged monitors. Also reports other keyDowns so a dictation can
/// cancel when the key was meant as a modifier (Fn plus arrow keys, for example)
/// and Esc can abort a session.
final class DictationKeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onOtherKeyDown: ((UInt16) -> Void)?

    private(set) var keyIsDown = false

    /// The key to watch. Changing it while the key is held would leave
    /// `keyIsDown` stale and the dictation would never end, so the release is
    /// reported as if the user had let go.
    var key: DictationKey {
        didSet {
            guard key != oldValue, keyIsDown else { return }
            keyIsDown = false
            onKeyUp?()
        }
    }

    private var monitors: [Any] = []
    private var keyMonitors: [Any] = []

    init(key: DictationKey = .default) {
        self.key = key
    }

    /// Key monitoring only runs during a dictation.
    ///
    /// A global `.keyDown` monitor wakes this process on EVERY keystroke in the
    /// whole system, including typing in another app. Orbly only needs to evaluate
    /// them while recording or transcribing (Esc aborts, any other key means the
    /// dictation key was meant as a modifier). The `.flagsChanged` monitor on the
    /// other hand has to run permanently, otherwise the key press would never
    /// arrive.
    func setKeyMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            guard keyMonitors.isEmpty else { return }
            let keyHandler: (NSEvent) -> Void = { [weak self] event in
                self?.onOtherKeyDown?(event.keyCode)
            }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keyHandler) {
                keyMonitors.append(m)
            }
            keyMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                keyHandler(e); return e
            } as Any)
        } else {
            for m in keyMonitors { NSEvent.removeMonitor(m) }
            keyMonitors.removeAll()
        }
    }

    func start() {
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            self.apply(keyCode: event.keyCode, modifiers: event.modifierFlags)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            flagsHandler(e); return e
        } as Any)
    }

    /// Forgets that the key is held, without reporting a release.
    ///
    /// Needed because a missed release used to disable dictation for good: the
    /// watchdog ended the recording, but `keyIsDown` stayed true, and every
    /// later press was then read as a repeat and ignored. The only way out was
    /// to quit the app. Whoever ends a dictation without a release event has to
    /// clear the state here.
    func clearHeldState() {
        keyIsDown = false
    }

    /// The whole decision of one flagsChanged event, kept apart from AppKit so it
    /// can be tested without synthesizing events.
    ///
    /// The keyCode says WHICH key changed, which is the only way to tell the left
    /// modifier from the right one. The flag says whether it is down now.
    func apply(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard keyCode == key.keyCode else { return }
        let down = modifiers.contains(key.modifier)
        if down && !keyIsDown {
            keyIsDown = true
            onKeyDown?()
        } else if !down && keyIsDown {
            keyIsDown = false
            onKeyUp?()
        }
    }
}
