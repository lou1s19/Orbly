import AppKit

/// Inserts text at the cursor of the frontmost app: puts it on the clipboard,
/// synthesizes Cmd+V, then restores the previous clipboard content.
enum TextInserter {
    enum Outcome {
        case inserted
        /// Bedienungshilfen-Berechtigung fehlt - Text bleibt in der Zwischenablage.
        case noPermission
        /// Der Nutzer ist inzwischen in einer anderen App - Text bleibt in der Zwischenablage.
        case appSwitched
        /// Im Ziel nimmt gerade nichts Text an, etwa im Finder oder auf dem
        /// Schreibtisch - Text bleibt in der Zwischenablage.
        case noTextField
    }

    /// Konvention von Passwort-Managern: Clipboard-Manager zeichnen Einträge
    /// mit diesem Marker nicht auf - Diktate landen so nicht in deren Historie.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// True, während die App ihr eigenes ⌘V sendet. Der globale Tasten-Monitor
    /// sieht dieses Ereignis ebenfalls und würde ein gerade gestartetes neues
    /// Diktat als „Fn als Modifier benutzt" abbrechen.
    private(set) static var isPasting = false

    /// Das Ergebnis steht erst asynchron fest: Der Fokus kann noch kurz vor dem
    /// ⌘V wechseln. `completion` läuft immer auf dem Hauptthread.
    static func insert(
        _ text: String,
        targetApp: NSRunningApplication? = nil,
        completion: @escaping (Outcome) -> Void
    ) {
        let pb = NSPasteboard.general
        let snapshot = snapshotItems(of: pb)

        copyToClipboard(text)
        let ourChangeCount = pb.changeCount

        guard AXIsProcessTrusted() else { return completion(.noPermission) }

        // Zwischen Diktatstart und Serverantwort können viele Sekunden liegen -
        // ist inzwischen eine andere App vorne, kein Cmd+V blind dorthin senden.
        if let targetApp,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != targetApp.processIdentifier {
            NSLog("Orbly: Einfügen übersprungen - \(front.localizedName ?? "andere App") ist vorne statt \(targetApp.localizedName ?? "Ziel-App")")
            return completion(.appSwitched)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Fokus kann sich in den 50 ms noch ändern - direkt vorm Senden nochmal prüfen.
            // Der Text bleibt dann in der Zwischenablage (⌘V).
            if let targetApp,
               let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != targetApp.processIdentifier {
                NSLog("Orbly: Einfügen abgebrochen - Fokuswechsel kurz vor ⌘V")
                completion(.appSwitched)
                return
            }
            // Ein ⌘V ins Leere sieht aus, als wäre das Diktat verschwunden:
            // Der Text ist nirgends aufgetaucht und die Zwischenablage wird
            // 0,7 s später auch noch zurückgesetzt.
            if let app = targetApp ?? NSWorkspace.shared.frontmostApplication,
               acceptsText(app) == false {
                NSLog("Orbly: Einfügen übersprungen - in \(app.localizedName ?? "der App") nimmt gerade nichts Text an")
                completion(.noTextField)
                return
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // V
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            isPasting = true
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            // Die Ereignisse laufen durchs System und kommen erst danach im
            // eigenen Monitor an - das Flag darf also nicht sofort fallen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isPasting = false }
            completion(.inserted)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                // Nur wiederherstellen, wenn niemand die Zwischenablage
                // inzwischen selbst geändert hat.
                guard pb.changeCount == ourChangeCount else { return }
                pb.clearContents()
                // War die Zwischenablage vorher leer (z. B. frisch angemeldet),
                // bleibt sie leer - sonst stünde das ganze Diktat dauerhaft drin.
                guard !snapshot.isEmpty else { return }
                pb.writeObjects(snapshot)
            }
        }
    }

    /// Legt den Text (mit Concealed-Marker) in die Zwischenablage, ohne einzufügen.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: concealedType)
        pb.writeObjects([item])
    }

    // MARK: - Nimmt das Ziel überhaupt Text an?

    /// `false` heißt „hier kommt nichts an", `true` heißt „Textfeld im Fokus",
    /// `nil` heißt „nicht feststellbar". Chromium-Apps (Chrome, Slack, VS Code)
    /// melden auch bei aktivem Textfeld kein fokussiertes Element und lassen den
    /// Menüpunkt „Einfügen" immer aktiv, gemessen am 2026-08-17. Bei ihnen bleibt
    /// es deshalb bei `nil` und es wird eingefügt wie bisher: Eine falsche Warnung
    /// wäre schlimmer als eine fehlende.
    private static func acceptsText(_ app: NSRunningApplication) -> Bool? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Antwortet die Ziel-App nicht, darf Orbly nicht mit ihr einfrieren.
        // Der Wert gilt pro Aufruf, deshalb hat die Menüsuche zusätzlich ein
        // Gesamtbudget: gemessen braucht sie 4 bis 10 ms.
        AXUIElementSetMessagingTimeout(axApp, 0.15)

        if let focused = element(of: axApp, attribute: kAXFocusedUIElementAttribute), isTextTarget(focused) {
            return true
        }
        // Zweites Signal: Der Finder und andere native Apps schalten „Einsetzen"
        // ab, solange nur Text in der Zwischenablage liegt und nichts ihn annimmt.
        return pasteMenuItemEnabled(of: axApp)
    }

    private static let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    /// Bedienelemente, deren Wert zwar beschreibbar ist, die aber keinen Text
    /// annehmen (ein Regler nimmt Zahlen, kein Diktat).
    private static let controlRoles = [
        kAXSliderRole, kAXIncrementorRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXButtonRole, kAXPopUpButtonRole, kAXMenuItemRole, kAXColorWellRole,
        kAXDisclosureTriangleRole, kAXImageRole, kAXStaticTextRole,
    ]

    private static func isTextTarget(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String
        if let role, textRoles.contains(role) { return true }
        if let role, controlRoles.contains(role) { return false }
        // Beschreibbarer Wert: hier kann Text hinein, egal wie die Rolle heißt.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Sucht den Menüpunkt mit dem Kürzel ⌘V (der Titel ist sprachabhängig,
    /// das Kürzel nicht) und meldet, ob er aktiv ist. Kostet rund 10 ms.
    private static func pasteMenuItemEnabled(of axApp: AXUIElement) -> Bool? {
        guard let bar = element(of: axApp, attribute: kAXMenuBarAttribute) else { return nil }
        // Hängt die Ziel-App, läuft jeder einzelne Aufruf in den Timeout. Lieber
        // ohne Antwort weitermachen als das Einfügen sekundenlang aufhalten.
        let deadline = Date().addingTimeInterval(0.25)
        for menu in children(of: bar) {
            for submenu in children(of: menu) {
                for item in children(of: submenu) {
                    if Date() > deadline { return nil }
                    var key: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &key) == .success,
                          (key as? String)?.lowercased() == "v" else { continue }
                    // 0 = nur die Befehlstaste, also das echte Einfügen und
                    // nicht „Inhalte einfügen" (⌘⌥⇧V) und Ähnliches.
                    var modifiers: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, kAXMenuItemCmdModifiersAttribute as CFString, &modifiers)
                    guard (modifiers as? Int) == 0 else { continue }
                    var enabled: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabled) == .success else {
                        return nil
                    }
                    return enabled as? Bool
                }
            }
        }
        return nil
    }

    private static func element(of parent: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    /// Kopiert alle Items mit allen Typen (auch Bilder/Rich-Text), nicht nur Plaintext.
    private static func snapshotItems(of pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}
