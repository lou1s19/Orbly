import AppKit

/// The key that starts a dictation.
///
/// Only modifier keys are offered, because dictation is push to talk: you hold
/// the key while speaking. A normal key would repeat, and a combination would
/// collide with the rule that any other key press cancels the dictation.
///
/// Fn is the default and the reason the choice exists at all: macOS uses Fn to
/// switch the input source, so anyone who types in more than one language needs
/// it for that (issue #2).
///
/// Only right-hand modifiers are offered. The left ones carry almost every
/// shortcut, so holding one for a second would fight with everyday use.
enum DictationKey: String, CaseIterable {
    case fn
    case rightCommand
    case rightOption
    case rightControl

    /// The default for a fresh installation and for everyone who never changed it.
    static let `default`: DictationKey = .fn

    /// `keyCode` of the flagsChanged event. This is what tells the left key from
    /// the right one; the modifier flag alone cannot.
    var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .rightOption: return 61
        case .rightControl: return 62
        }
    }

    /// Whether the key is held right now. Read from the flags of the event and,
    /// for the watchdog, from `NSEvent.modifierFlags`.
    var modifier: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .rightCommand: return .command
        case .rightOption: return .option
        case .rightControl: return .control
        }
    }

    /// Device dependent bit for exactly this key. macOS reports it next to the
    /// side independent flag, and it is the only thing that tells the left
    /// modifier from the right one once both are held.
    var deviceMask: UInt {
        switch self {
        case .fn: return 0                      // there is only one Fn key
        case .rightCommand: return 0x000010     // NX_DEVICERCMDKEYMASK
        case .rightOption: return 0x000040      // NX_DEVICERALTKEYMASK
        case .rightControl: return 0x002000     // NX_DEVICERCTLKEYMASK
        }
    }

    /// Both device bits of the modifier, left and right.
    private var bothSidesMask: UInt {
        switch self {
        case .fn: return 0
        case .rightCommand: return 0x000018     // left 0x08 plus right 0x10
        case .rightOption: return 0x000060      // left 0x20 plus right 0x40
        case .rightControl: return 0x002001     // left 0x01 plus right 0x2000
        }
    }

    /// Whether THIS key is held, not just any key carrying the same modifier.
    ///
    /// Holding left and right Command at once and letting go of the right one
    /// leaves `.command` set, so the side independent flag would miss the
    /// release and the recording would run to the ten minute limit. The device
    /// bits tell the sides apart.
    ///
    /// They are not guaranteed to be present in every event, so they are only
    /// trusted when the event carries a bit for this modifier at all. Otherwise
    /// this falls back to the side independent flag, which is how it worked
    /// before and is right whenever only one side is in play.
    func isHeld(in modifiers: NSEvent.ModifierFlags) -> Bool {
        guard deviceMask != 0, modifiers.rawValue & bothSidesMask != 0 else {
            return modifiers.contains(modifier)
        }
        return modifiers.rawValue & deviceMask != 0
    }

    /// What the key cap in the tour and the overlay shows.
    var symbol: String {
        switch self {
        case .fn: return "fn"
        case .rightCommand: return "⌘"
        case .rightOption: return "⌥"
        case .rightControl: return "⌃"
        }
    }

    /// The name used in running text ("hold Fn to dictate"). Translated, because
    /// "right" is a word; the symbols themselves are not translated.
    var displayName: String {
        switch self {
        case .fn: return "Fn"
        default: return L10n.t("key.\(rawValue)")
        }
    }

    /// Options for the picker, in the order they are offered.
    static var pickerOptions: [(value: String, label: String)] {
        allCases.map { ($0.rawValue, $0 == .fn ? "fn" : "\($0.symbol) \(L10n.t("key.side.right"))") }
    }
}
