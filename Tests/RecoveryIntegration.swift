import AppKit
import Carbon
import Foundation

// Run only against an installed ReleaseSwitch 1.2.1. Secure input is enabled
// briefly by this process and balanced with DisableSecureEventInput.
@main struct RecoveryIntegration {
    static func status() throws -> [String: Any] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReleaseSwitch/status.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }
    static func wait(_ predicate: ([String: Any]) -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if predicate(try status()) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SetupError.message("Installed app did not reach the expected recovery state")
    }
    static func main() throws {
        guard !IsSecureEventInputEnabled() else { throw SetupError.message("Another process owns secure input") }
        guard try status()["version"] as? String == "1.2.1" else { throw SetupError.message("Install version 1.2.1 first") }
        try wait { $0["active"] as? Bool == true }
        guard EnableSecureEventInput() == noErr else { throw SetupError.message("Secure input could not be enabled") }
        var ownsSecureInput = true
        defer { if ownsSecureInput { DisableSecureEventInput() } }
        try wait { $0["secureInput"] as? Bool == true && $0["active"] as? Bool == false && $0["monitorOpen"] as? Bool == false }
        print("PASS: protected input stops the installed monitor and updates status")
        guard DisableSecureEventInput() == noErr else { throw SetupError.message("Secure input could not be disabled") }
        ownsSecureInput = false
        try wait { $0["secureInput"] as? Bool == false && $0["active"] as? Bool == true && ($0["fnElements"] as? Int ?? 0) > 0 }
        print("PASS: installed monitor automatically recreated after protected input ended")
    }
}
