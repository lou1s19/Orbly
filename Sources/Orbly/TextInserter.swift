import AppKit

/// Inserts text at the cursor of the frontmost app: puts it on the clipboard,
/// synthesizes Cmd+V, then restores the previous clipboard content.
enum TextInserter {
    enum Outcome {
        case inserted
        /// Accessibility permission is missing, the text stays in the clipboard.
        case noPermission
        /// The user is in another app by now, the text stays in the clipboard.
        case appSwitched
        /// Nothing in the target accepts text right now, for example in the Finder or
        /// on the desktop. The text stays in the clipboard.
        case noTextField
    }

    /// Convention of password managers: clipboard managers do not record entries
    /// carrying this marker, so dictations stay out of their history.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// True while the app sends its own ⌘V. The global key monitor sees that event
    /// too and would cancel a dictation that just started, reading it as "Fn used
    /// as a modifier".
    private(set) static var isPasting = false

    /// The result is only known asynchronously: the focus can still change shortly
    /// before the ⌘V. `completion` always runs on the main thread.
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

        // Many seconds can pass between the start of a dictation and the server
        // response. If another app is in front by then, do not blindly send Cmd+V.
        if let targetApp,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != targetApp.processIdentifier {
            NSLog("Orbly: insertion skipped, \(front.localizedName ?? "another app") is in front instead of \(targetApp.localizedName ?? "the target app")")
            return completion(.appSwitched)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // The focus can still change during those 50 ms, so check again right
            // before sending. The text then stays in the clipboard (⌘V).
            if let targetApp,
               let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != targetApp.processIdentifier {
                NSLog("Orbly: insertion cancelled, the focus changed shortly before ⌘V")
                completion(.appSwitched)
                return
            }
            // A ⌘V into the void looks as if the dictation vanished: the text
            // showed up nowhere, and 0.7 s later the clipboard is restored on
            // top of that.
            if let app = targetApp ?? NSWorkspace.shared.frontmostApplication,
               acceptsText(app) == false {
                NSLog("Orbly: insertion skipped, nothing in \(app.localizedName ?? "the app") accepts text right now")
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
            // The events travel through the system and only reach our own monitor
            // afterwards, so the flag must not drop immediately.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isPasting = false }
            completion(.inserted)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                // Only restore when nobody changed the clipboard themselves in the
                // meantime.
                guard pb.changeCount == ourChangeCount else { return }
                pb.clearContents()
                // If the clipboard was empty before (freshly logged in, say), it stays
                // empty. Otherwise the whole dictation would sit in there permanently.
                guard !snapshot.isEmpty else { return }
                pb.writeObjects(snapshot)
            }
        }
    }

    /// Puts the text (with the concealed marker) on the clipboard without pasting.
    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: concealedType)
        pb.writeObjects([item])
    }

    // MARK: - Does the target accept text at all?

    /// `false` means "nothing arrives here", `true` means "a text field has focus",
    /// `nil` means "cannot tell". Chromium apps (Chrome, Slack, VS Code) report no
    /// focused element even with an active text field and leave the "Paste" menu
    /// item enabled at all times, measured on 2026-08-17. For them the answer
    /// stays `nil` and pasting happens as before: a wrong warning would be worse
    /// than a missing one.
    private static func acceptsText(_ app: NSRunningApplication) -> Bool? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // If the target app does not answer, Orbly must not freeze with it. The
        // value applies per call, so the menu search has an overall budget on top
        // of it: measured, it needs 4 to 10 ms.
        AXUIElementSetMessagingTimeout(axApp, 0.15)

        if let focused = element(of: axApp, attribute: kAXFocusedUIElementAttribute), isTextTarget(focused) {
            return true
        }
        // Second signal: the Finder and other native apps disable "Paste" while
        // there is only text in the clipboard and nothing accepts it.
        return pasteMenuItemEnabled(of: axApp)
    }

    private static let textRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

    /// Controls whose value is writable but that do not accept text (a slider
    /// takes numbers, not a dictation).
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
        // Writable value: text can go in here, whatever the role is called.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    /// Looks for the menu item with the ⌘V shortcut (the title depends on the
    /// language, the shortcut does not) and reports whether it is enabled. Costs about 10 ms.
    private static func pasteMenuItemEnabled(of axApp: AXUIElement) -> Bool? {
        guard let bar = element(of: axApp, attribute: kAXMenuBarAttribute) else { return nil }
        // If the target app hangs, every single call runs into the timeout. Better
        // to carry on without an answer than to hold up pasting for seconds.
        let deadline = Date().addingTimeInterval(0.25)
        for menu in children(of: bar) {
            for submenu in children(of: menu) {
                for item in children(of: submenu) {
                    if Date() > deadline { return nil }
                    var key: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXMenuItemCmdCharAttribute as CFString, &key) == .success,
                          (key as? String)?.lowercased() == "v" else { continue }
                    // 0 = the command key only, so the real paste and not
                    // "Paste Special" (⌘⌥⇧V) and the like.
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

    /// Copies all items with all types (images/rich text too), not just plain text.
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
