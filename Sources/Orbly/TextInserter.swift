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
    }

    /// Konvention von Passwort-Managern: Clipboard-Manager zeichnen Einträge
    /// mit diesem Marker nicht auf - Diktate landen so nicht in deren Historie.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// True, während die App ihr eigenes ⌘V sendet. Der globale Tasten-Monitor
    /// sieht dieses Ereignis ebenfalls und würde ein gerade gestartetes neues
    /// Diktat als „Fn als Modifier benutzt" abbrechen.
    private(set) static var isPasting = false

    @discardableResult
    static func insert(_ text: String, targetApp: NSRunningApplication? = nil) -> Outcome {
        let pb = NSPasteboard.general
        let snapshot = snapshotItems(of: pb)

        copyToClipboard(text)
        let ourChangeCount = pb.changeCount

        guard AXIsProcessTrusted() else { return .noPermission }

        // Zwischen Diktatstart und Serverantwort können viele Sekunden liegen -
        // ist inzwischen eine andere App vorne, kein Cmd+V blind dorthin senden.
        if let targetApp,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != targetApp.processIdentifier {
            NSLog("Orbly: Einfügen übersprungen - \(front.localizedName ?? "andere App") ist vorne statt \(targetApp.localizedName ?? "Ziel-App")")
            return .appSwitched
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Fokus kann sich in den 50 ms noch ändern - direkt vorm Senden nochmal prüfen.
            // Der Text bleibt dann in der Zwischenablage (⌘V).
            if let targetApp,
               let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != targetApp.processIdentifier {
                NSLog("Orbly: Einfügen abgebrochen - Fokuswechsel kurz vor ⌘V")
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
        return .inserted
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
