import AppKit

/// Watches the Fn/Globe key (keyCode 63) via global+local flagsChanged monitors.
/// Also reports other keyDowns so dictation can cancel when Fn is used as a modifier
/// (e.g. Fn+arrow keys) and Esc can abort a session.
final class FnKeyMonitor {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    var onOtherKeyDown: ((UInt16) -> Void)?

    private(set) var fnIsDown = false
    private var monitors: [Any] = []
    private var keyMonitors: [Any] = []

    /// Die Tastenüberwachung läuft nur während eines Diktats.
    ///
    /// Ein globaler `.keyDown`-Monitor weckt diesen Prozess bei JEDEM Tastendruck
    /// im ganzen System auf, also auch beim Schreiben in einer anderen App. Die
    /// Auswertung braucht Orbly aber nur, solange aufgenommen oder transkribiert
    /// wird (Esc bricht ab, andere Tasten heißen "Fn war als Modifier gemeint").
    /// Der `.flagsChanged`-Monitor muss dagegen dauerhaft laufen, sonst käme der
    /// Fn-Druck nie an.
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
            guard let self, event.keyCode == 63 else { return }
            let down = event.modifierFlags.contains(.function)
            if down && !self.fnIsDown {
                self.fnIsDown = true
                self.onFnDown?()
            } else if !down && self.fnIsDown {
                self.fnIsDown = false
                self.onFnUp?()
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            flagsHandler(e); return e
        } as Any)
    }
}
