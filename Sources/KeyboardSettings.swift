import AppKit
import Foundation

enum SetupError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

final class KeyboardSettings {
    static let capsUsage: UInt64 = 0x700000039
    static let f18Usage: UInt64 = 0x70000006D
    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"
    // Restrict remapping to the built-in MacBook keyboard.
    static let matching = #"{"Product":"Apple Internal Keyboard / Trackpad","PrimaryUsagePage":1,"PrimaryUsage":6}"#
    private let preferences = UserDefaults.standard
    private let fnDomain = "com.apple.HIToolbox" as CFString
    private let fnKey = "AppleFnUsageType" as CFString

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SetupError.message("\(URL(fileURLWithPath: executable).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    static func parseMappings(_ text: String) throws -> [[String: UInt64]] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SetupError.message("Нет доступа к настройкам встроенной клавиатуры.")
        }
        if text.contains("(null)") { return [] }
        guard let first = text.firstIndex(of: "("), let last = text.lastIndex(of: ")") else {
            throw SetupError.message("Не удалось прочитать существующие переназначения клавиш.")
        }
        let data = Data(text[first...last].utf8)
        guard let array = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw SetupError.message("Неизвестный формат переназначений клавиш.")
        }
        return try array.map { entry in
            var result: [String: UInt64] = [:]
            for key in [sourceKey, destinationKey] {
                let value = (entry[key] as? NSNumber)?.uint64Value ?? (entry[key] as? String).flatMap(UInt64.init)
                guard let value else { throw SetupError.message("Неверный код клавиши в существующих настройках.") }
                result[key] = value
            }
            return result
        }
    }

    func mappings() throws -> [[String: UInt64]] {
        try Self.parseMappings(Self.run("/usr/bin/hidutil", ["property", "--matching", Self.matching, "--get", "UserKeyMapping"]))
    }

    private func setMappings(_ mappings: [[String: UInt64]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["UserKeyMapping": mappings], options: [.sortedKeys])
        try Self.run("/usr/bin/hidutil", ["property", "--matching", Self.matching, "--set", String(decoding: data, as: UTF8.self)])
    }

    func apply(fnEnabled: Bool = true, capsEnabled: Bool = true) throws {
        var current = try mappings()
        if !preferences.bool(forKey: "originalSettingsSaved") {
            if let originalFn = CFPreferencesCopyAppValue(fnKey, fnDomain) {
                preferences.set(originalFn, forKey: "originalFnUsage")
            }
            let originalCaps = current.filter { $0[Self.sourceKey] == Self.capsUsage }
            preferences.set(originalCaps, forKey: "originalCapsMappings")
            preferences.set(true, forKey: "originalSettingsSaved")
            preferences.synchronize()
        }
        // Remove the previous custom Caps Lock handler and restore the native key.
        if current.contains(where: { $0[Self.sourceKey] == Self.capsUsage && $0[Self.destinationKey] == Self.f18Usage }) {
            current.removeAll { $0[Self.sourceKey] == Self.capsUsage && $0[Self.destinationKey] == Self.f18Usage }
            if let original = preferences.array(forKey: "originalCapsMappings") as? [[String: UInt64]] {
                current.append(contentsOf: original)
            }
            try setMappings(current)
        }
        if !preferences.bool(forKey: "originalCapsDelaySaved") {
            let output = try Self.run("/usr/bin/hidutil", ["property", "--matching", Self.matching, "--get", "CapsLockDelayOverride"])
            let lastWord = output.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
            preferences.set(Int(lastWord) ?? -1, forKey: "originalCapsDelay")
            preferences.set(true, forKey: "originalCapsDelaySaved")
            preferences.synchronize()
        }
        let delay = capsEnabled ? 0 : preferences.integer(forKey: "originalCapsDelay")
        try Self.run("/usr/bin/hidutil", ["property", "--matching", Self.matching, "--set", "{\"CapsLockDelayOverride\":\(delay)}"])
        if fnEnabled {
            CFPreferencesSetAppValue(fnKey, 0 as CFNumber, fnDomain)
            CFPreferencesAppSynchronize(fnDomain)
        } else { restoreFn() }
    }

    func restore() throws {
        guard preferences.bool(forKey: "originalSettingsSaved") else { return }
        var current = try mappings()
        current.removeAll {
            $0[Self.sourceKey] == Self.capsUsage && $0[Self.destinationKey] == Self.f18Usage
        }
        if !current.contains(where: { $0[Self.sourceKey] == Self.capsUsage }),
           let original = preferences.array(forKey: "originalCapsMappings") as? [[String: UInt64]] {
            current.append(contentsOf: original)
        }
        try setMappings(current)
        if preferences.bool(forKey: "originalCapsDelaySaved") {
            let delay = preferences.integer(forKey: "originalCapsDelay")
            try Self.run("/usr/bin/hidutil", ["property", "--matching", Self.matching, "--set", "{\"CapsLockDelayOverride\":\(delay)}"])
        }
        restoreFn()
    }

    private func restoreFn() {
        if let originalFn = preferences.object(forKey: "originalFnUsage") {
            CFPreferencesSetAppValue(fnKey, originalFn as CFPropertyList, fnDomain)
        } else {
            CFPreferencesSetAppValue(fnKey, nil, fnDomain)
        }
        CFPreferencesAppSynchronize(fnDomain)
    }
}
