import AppKit
import XCTest
@testable import Orbly

/// The dictation key is the one thing every dictation goes through. A wrong
/// keyCode or a wrong modifier means the app looks dead, so the mapping is
/// pinned down here.
final class DictationKeyTests: XCTestCase {

    func testFnStaysTheDefault() {
        XCTAssertEqual(DictationKey.default, .fn)
        XCTAssertEqual(DictationKey(rawValue: "does-not-exist") ?? .default, .fn)
    }

    /// The keyCode is what tells the left key from the right one. Two keys with
    /// the same code would make one of them unreachable.
    func testEveryKeyHasItsOwnKeyCode() {
        let codes = DictationKey.allCases.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    /// Measured against the macOS virtual key codes. Getting one wrong means the
    /// key never triggers and there is nothing in the interface that would say so.
    func testKeyCodesMatchTheMacOSVirtualKeys() {
        XCTAssertEqual(DictationKey.fn.keyCode, 63)
        XCTAssertEqual(DictationKey.rightCommand.keyCode, 54)
        XCTAssertEqual(DictationKey.rightOption.keyCode, 61)
        XCTAssertEqual(DictationKey.rightControl.keyCode, 62)
    }

    func testModifierMatchesTheKey() {
        XCTAssertEqual(DictationKey.fn.modifier, .function)
        XCTAssertEqual(DictationKey.rightCommand.modifier, .command)
        XCTAssertEqual(DictationKey.rightOption.modifier, .option)
        XCTAssertEqual(DictationKey.rightControl.modifier, .control)
    }

    /// Only right-hand modifiers, because the left ones carry the shortcuts
    /// people use all day.
    func testOnlyRightHandModifiersAreOffered() {
        let leftHandCodes: Set<UInt16> = [55, 58, 59]  // left command, option, control
        for key in DictationKey.allCases {
            XCTAssertFalse(leftHandCodes.contains(key.keyCode), "\(key) is a left-hand key")
        }
    }

    func testPickerOffersEveryKey() {
        let values = DictationKey.pickerOptions.map(\.value)
        XCTAssertEqual(Set(values), Set(DictationKey.allCases.map(\.rawValue)))
        for option in DictationKey.pickerOptions {
            XCTAssertFalse(option.label.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// The name appears in running text, so a missing translation would show the
    /// raw L10n key to the user.
    func testKeyNamesExistInAllLanguages() {
        for key in DictationKey.allCases where key != .fn {
            for lang in ["en", "de", "es", "fr", "ru"] {
                XCTAssertNotNil(
                    L10n.tables[lang]?["key.\(key.rawValue)"],
                    "key.\(key.rawValue) is missing in \(lang)"
                )
            }
        }
        for lang in ["en", "de", "es", "fr", "ru"] {
            XCTAssertNotNil(L10n.tables[lang]?["key.side.right"], "key.side.right is missing in \(lang)")
        }
    }

    /// Every string that used to name Fn takes the key as a placeholder now.
    /// Without the placeholder the text would silently keep saying "Fn".
    func testStringsAboutTheKeyCarryAPlaceholder() {
        let keys = [
            "menu.ready", "menu.status.axMissing", "dashboard.chart.empty",
            "settings.hint", "onboarding.welcome.body", "onboarding.try.idle",
            "onboarding.done.hold", "onboarding.done.tap",
        ]
        for lang in ["en", "de", "es", "fr", "ru"] {
            for key in keys {
                let value = L10n.tables[lang]?[key] ?? ""
                XCTAssertTrue(value.contains("%@"), "\(lang) / \(key) does not name the key")
                XCTAssertFalse(value.contains("Fn"), "\(lang) / \(key) still hardwires Fn")
            }
        }
    }

    // MARK: - Telling the sides apart

    /// Holding left and right Command and letting go of the right one leaves
    /// `.command` set. Without the device bits the release would be missed and
    /// the recording would run to the ten minute limit.
    func testReleaseOfTheRightKeyIsSeenWhileTheLeftIsStillHeld() {
        let leftCommandHeld = NSEvent.ModifierFlags(rawValue: 0x000008 | NSEvent.ModifierFlags.command.rawValue)
        XCTAssertFalse(DictationKey.rightCommand.isHeld(in: leftCommandHeld))

        let bothHeld = NSEvent.ModifierFlags(rawValue: 0x000018 | NSEvent.ModifierFlags.command.rawValue)
        XCTAssertTrue(DictationKey.rightCommand.isHeld(in: bothHeld))
    }

    func testTheSameHoldsForOptionAndControl() {
        let leftOption = NSEvent.ModifierFlags(rawValue: 0x000020 | NSEvent.ModifierFlags.option.rawValue)
        XCTAssertFalse(DictationKey.rightOption.isHeld(in: leftOption))
        let rightOption = NSEvent.ModifierFlags(rawValue: 0x000040 | NSEvent.ModifierFlags.option.rawValue)
        XCTAssertTrue(DictationKey.rightOption.isHeld(in: rightOption))

        let leftControl = NSEvent.ModifierFlags(rawValue: 0x000001 | NSEvent.ModifierFlags.control.rawValue)
        XCTAssertFalse(DictationKey.rightControl.isHeld(in: leftControl))
        let rightControl = NSEvent.ModifierFlags(rawValue: 0x002000 | NSEvent.ModifierFlags.control.rawValue)
        XCTAssertTrue(DictationKey.rightControl.isHeld(in: rightControl))
    }

    /// The device bits are not guaranteed to be in every event. Without them the
    /// side independent flag has to keep working, exactly as before.
    func testWithoutDeviceBitsTheModifierFlagStillDecides() {
        XCTAssertTrue(DictationKey.rightCommand.isHeld(in: [.command]))
        XCTAssertFalse(DictationKey.rightCommand.isHeld(in: [.option]))
        XCTAssertFalse(DictationKey.rightCommand.isHeld(in: []))
    }

    /// There is only one Fn key, so there is nothing to tell apart.
    func testFnHasNoSides() {
        XCTAssertEqual(DictationKey.fn.deviceMask, 0)
        XCTAssertTrue(DictationKey.fn.isHeld(in: [.function]))
        XCTAssertFalse(DictationKey.fn.isHeld(in: [.command]))
    }

    // MARK: - Monitor

    func testPressAndReleaseOfTheConfiguredKey() {
        let monitor = DictationKeyMonitor(key: .rightOption)
        var downs = 0, ups = 0
        monitor.onKeyDown = { downs += 1 }
        monitor.onKeyUp = { ups += 1 }

        monitor.apply(keyCode: 61, modifiers: [.option])
        XCTAssertTrue(monitor.keyIsDown)
        XCTAssertEqual(downs, 1)

        // A repeat of the same event must not start a second dictation.
        monitor.apply(keyCode: 61, modifiers: [.option])
        XCTAssertEqual(downs, 1)

        monitor.apply(keyCode: 61, modifiers: [])
        XCTAssertFalse(monitor.keyIsDown)
        XCTAssertEqual(ups, 1)
    }

    /// The left modifier sends the same flag, only the keyCode differs. Without
    /// the keyCode check, pressing left Command would start a dictation.
    func testTheOtherSideOfTheSameModifierIsIgnored() {
        let monitor = DictationKeyMonitor(key: .rightCommand)
        var downs = 0
        monitor.onKeyDown = { downs += 1 }
        monitor.apply(keyCode: 55, modifiers: [.command])   // left Command
        XCTAssertFalse(monitor.keyIsDown)
        XCTAssertEqual(downs, 0)
    }

    func testAnotherModifierDoesNotTrigger() {
        let monitor = DictationKeyMonitor(key: .fn)
        var downs = 0
        monitor.onKeyDown = { downs += 1 }
        monitor.apply(keyCode: 62, modifiers: [.control])
        XCTAssertEqual(downs, 0)
    }

    /// Changing the key mid-dictation would otherwise leave the monitor thinking
    /// the old key is still held, and the dictation would never end.
    func testSwitchingTheKeyEndsARunningPress() {
        let monitor = DictationKeyMonitor(key: .fn)
        var ups = 0
        monitor.onKeyUp = { ups += 1 }
        monitor.apply(keyCode: 63, modifiers: [.function])
        XCTAssertTrue(monitor.keyIsDown)

        monitor.key = .rightCommand
        XCTAssertFalse(monitor.keyIsDown)
        XCTAssertEqual(ups, 1, "the running dictation has to be ended")
    }

    /// A missed release used to disable dictation for good: the watchdog ended
    /// the recording, but the monitor still believed the key was held, so every
    /// later press read as a repeat and was ignored.
    func testAfterAMissedReleaseTheNextPressStillWorks() {
        let monitor = DictationKeyMonitor(key: .rightOption)
        var downs = 0
        monitor.onKeyDown = { downs += 1 }

        monitor.apply(keyCode: 61, modifiers: [.option])
        XCTAssertEqual(downs, 1)

        // The release never arrives. Whoever ends the dictation clears the state.
        monitor.clearHeldState()
        XCTAssertFalse(monitor.keyIsDown)

        monitor.apply(keyCode: 61, modifiers: [.option])
        XCTAssertEqual(downs, 2, "the next press has to start a dictation again")
    }

    func testClearingTheHeldStateReportsNoRelease() {
        let monitor = DictationKeyMonitor(key: .fn)
        var ups = 0
        monitor.onKeyUp = { ups += 1 }
        monitor.apply(keyCode: 63, modifiers: [.function])
        monitor.clearHeldState()
        XCTAssertEqual(ups, 0, "the caller already ended the dictation itself")
    }

    func testSwitchingTheKeyWhileNothingIsHeldStaysQuiet() {
        let monitor = DictationKeyMonitor(key: .rightOption)
        var ups = 0
        monitor.onKeyUp = { ups += 1 }
        monitor.key = .rightControl
        monitor.key = .rightControl
        XCTAssertEqual(ups, 0)
    }
}
