import Foundation
import ServiceManagement

final class LoginController {
    private let service = SMAppService.mainApp
    private let legacyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.andrey.ReleaseSwitch.plist")

    var enabled: Bool { service.status == .enabled || service.status == .requiresApproval }
    var needsApproval: Bool { service.status == .requiresApproval }
    var description: String {
        switch service.status {
        case .enabled: return "Программа запускается при входе в систему."
        case .requiresApproval: return "Разреши запуск в настройках объектов входа."
        case .notRegistered: return "Можно запускать программу самостоятельно."
        case .notFound: return "Перемести приложение в «Программы» и открой снова."
        @unknown default: return "Проверь настройки объектов входа."
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if service.status != .enabled && service.status != .requiresApproval { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
        // Migrate our earlier installer without killing a process launched by it.
        // The disabled legacy job can finish normally; future logins use SMAppService.
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            let data = try Data(contentsOf: legacyURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard plist?["Label"] as? String == "local.andrey.ReleaseSwitch" else {
                throw SetupError.message("Старый объект входа имеет неизвестный формат.")
            }
            try KeyboardSettings.run("/bin/launchctl", ["disable", "gui/\(getuid())/local.andrey.ReleaseSwitch"])
            let backup = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ReleaseSwitch/legacy-autostart.plist")
            try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup) }
            try FileManager.default.removeItem(at: legacyURL)
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
