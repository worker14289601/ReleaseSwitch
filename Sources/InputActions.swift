import AppKit
import Carbon
import IOKit

final class InputActions {
    private var connection: io_connect_t = 0
    private lazy var switcher = LanguageSwitcher(access: SourceAccess(
        enabledIDs: { try Self.inputSources().compactMap { Self.sourceID($0) } },
        currentID: {
            let id = Self.currentSourceID()
            guard id != "unknown" else { throw SetupError.message("Текущая раскладка недоступна.") }
            return id
        },
        select: { id in
            guard let source = try Self.inputSources().first(where: { Self.sourceID($0) == id }) else {
                throw SetupError.message("Выбранная раскладка больше не доступна.")
            }
            let result = TISSelectInputSource(source)
            guard result == noErr else { throw SetupError.message("Не удалось переключить раскладку: \(result).") }
        }
    ))

    deinit { if connection != 0 { IOServiceClose(connection) } }

    // Caps Lock remains native. This connection is used only for diagnostics;
    // its availability must never prevent Fn from starting.
    func capsLockState() throws -> Bool {
        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
            guard service != 0 else { throw SetupError.message("IOHIDSystem недоступен.") }
            defer { IOObjectRelease(service) }
            let result = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
            guard result == KERN_SUCCESS else { throw SetupError.message("Не удалось прочитать Caps Lock: \(result).") }
        }
        var state = false
        let result = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state)
        guard result == KERN_SUCCESS else {
            IOServiceClose(connection)
            connection = 0
            throw SetupError.message("Не удалось прочитать Caps Lock: \(result).")
        }
        return state
    }

    static func sourceProperty(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        sourceProperty(source, kTISPropertyInputSourceID) as? String
    }

    static func inputSources() throws -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            throw SetupError.message("macOS не предоставила список раскладок.")
        }
        return list.filter {
            sourceProperty($0, kTISPropertyInputSourceCategory) as? String == kTISCategoryKeyboardInputSource as String
                && sourceProperty($0, kTISPropertyInputSourceIsSelectCapable) as? Bool == true
                && sourceProperty($0, kTISPropertyInputSourceIsEnabled) as? Bool == true
        }
    }

    static func currentSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "unknown" }
        return sourceID(source) ?? "unknown"
    }

    func switchLanguage(_ completion: @escaping LanguageSwitcher.Completion) { switcher.request(completion) }
    func cancelPendingSwitches() { switcher.cancel() }
}
