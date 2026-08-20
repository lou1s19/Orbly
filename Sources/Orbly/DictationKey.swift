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
