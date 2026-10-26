import AppKit
import Carbon

// Tests actual TIS selection and confirmation, then restores the original source.
// Caps Lock is read only; it retains the native macOS handler.
@main struct Integration {
    static func main() throws {
        let actions = InputActions()
        let original = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
        let originalID = InputActions.currentSourceID()
        let originalCaps = try actions.capsLockState()
        defer { actions.cancelPendingSwitches(); TISSelectInputSource(original) }
        var outcome: Result<String, Error>?
        actions.switchLanguage { outcome = $0 }
        let deadline = Date().addingTimeInterval(2)
        while outcome == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard let outcome else { throw SetupError.message("Confirmation timed out") }
        let confirmed = try outcome.get()
        guard confirmed != originalID && InputActions.currentSourceID() == confirmed else {
            throw SetupError.message("The system did not change the source")
        }
        guard try actions.capsLockState() == originalCaps else {
            throw SetupError.message("Native Caps Lock state unexpectedly changed")
        }
        print("PASS: actual language selection confirmed; native Caps Lock preserved")
        guard TISSelectInputSource(original) == noErr else {
            throw SetupError.message("Original input source not restored")
        }
        let restoreDeadline = Date().addingTimeInterval(2)
        while InputActions.currentSourceID() != originalID && Date() < restoreDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard InputActions.currentSourceID() == originalID else {
            throw SetupError.message("Original input source not confirmed")
        }
        print("PASS: original input source restored")
    }
}
