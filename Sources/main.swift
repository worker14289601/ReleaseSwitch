import AppKit
import ApplicationServices
import Carbon
import Foundation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var window: NSWindow?
    private var healthTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var actions: InputActions?
    private var monitor: EventMonitor?
    private let diagnosticActions = InputActions()
    private let settings = KeyboardSettings()
    private let statistics = MonitorStatistics()
    private let login = LoginController()
    private let model = AppViewModel()
    private var didApplySettings = false
    private var didLaunch = false
    private var sleeping = false
    private var resumeAt: TimeInterval = 0
    private var lastActionError = ""
    private var configurationError = ""
    private var loginError = ""
    private var configurationDirty = true
    private var lastConfigurationAttempt: TimeInterval = 0
    private var lastStatusWrite: TimeInterval = 0
    private var lastStatusData = Data()
    private let previewMode = Bundle.main.object(forInfoDictionaryKey: "ReleaseSwitchPreviewMode") as? String
    private var preview: Bool { previewMode != nil }
    private var fnEnabled: Bool { UserDefaults.standard.bool(forKey: "fnEnabled") }
    private var capsEnabled: Bool { UserDefaults.standard.bool(forKey: "capsEnabled") }
    private var showMenuBarIcon: Bool { UserDefaults.standard.bool(forKey: "showMenuBarIcon") }
    private let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ReleaseSwitch", isDirectory: true)
    private var installed: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return path == "/Applications" || path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }
    private lazy var supervisor = RuntimeSupervisor(
        start: { [weak self] in try self?.startMonitoring() },
        stop: { [weak self] in self?.stopMonitoring() },
        check: { [weak self] in
            guard let monitor = self?.monitor else { throw SetupError.message("Обработчик Fn остановлен.") }
            try monitor.checkHealth()
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if preview { launchPreview(); return }
        UserDefaults.standard.register(defaults: ["fnEnabled": true, "capsEnabled": true, "showMenuBarIcon": true])
        waitForRelaunchThenStart()
    }

    private func waitForRelaunchThenStart() {
        if let index = CommandLine.arguments.firstIndex(of: "--wait-for"),
           CommandLine.arguments.indices.contains(index + 1),
           let pid = Int32(CommandLine.arguments[index + 1]), NSRunningApplication(processIdentifier: pid) != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitForRelaunchThenStart() }
            return
        }
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: "local.andrey.ReleaseSwitch")
            .filter { $0.processIdentifier != getpid() }
        if let other = otherInstances.first {
            if let url = other.bundleURL { NSWorkspace.shared.open(url) }
            else { other.activate(options: [.activateAllWindows]) }
            NSApp.terminate(nil)
            return
        }
        didLaunch = true
        connectWindowActions()
        createMenu()
        observeLifecycle()
        if installed && !UserDefaults.standard.bool(forKey: "nativeLoginConfigured") {
            do { try login.setEnabled(true) }
            catch { loginError = "Не удалось включить автозапуск: \(error.localizedDescription)" }
            UserDefaults.standard.set(true, forKey: "nativeLoginConfigured")
        }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        tick()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        if !atLogin || !installed || !model.permissionsReady { showWindow() }
        if installed && !model.permissionsReady && !UserDefaults.standard.bool(forKey: "permissionPromptShown") {
            UserDefaults.standard.set(true, forKey: "permissionPromptShown")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.requestPermissions() }
        }
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ReleaseSwitch")
        let menu = NSMenu()
        menu.addItem(item("Открыть ReleaseSwitch…", #selector(showWindow)))
        statusLine = NSMenuItem(title: "Подготовка…", action: nil, keyEquivalent: "")
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Проверить клавиши…", #selector(showKeyboardTest)))
        menu.addItem(item("Настройки клавиатуры…", #selector(openKeyboardSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Выйти и восстановить клавиши", #selector(quit)))
        statusItem.menu = menu
        statusItem.isVisible = preview ? model.showMenuBarIcon : showMenuBarIcon
    }

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sleeping = true
                self.supervisor.suspend(.sleeping)
                self.refreshStatus(force: true)
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.sleeping = false
                self.configurationDirty = true
                self.resumeAt = ProcessInfo.processInfo.systemUptime + 1
                self.supervisor.suspend(.sleeping)
                self.refreshStatus(force: true)
            }
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func connectWindowActions() {
        model.onFnChanged = { [weak self] value in self?.setFeature("fnEnabled", value) }
        model.onCapsChanged = { [weak self] value in self?.setFeature("capsEnabled", value) }
        model.onMenuBarIconChanged = { [weak self] value in
            guard let self else { return }
            UserDefaults.standard.set(value, forKey: "showMenuBarIcon")
            self.statusItem?.isVisible = value
            self.refreshStatus(force: true)
        }
        model.onLoginChanged = { [weak self] value in
            guard let self else { return }
            do { try self.login.setEnabled(value); self.loginError = ""; self.showNotice(value ? "Автозапуск включён" : "Автозапуск выключен") }
            catch { self.loginError = error.localizedDescription }
            self.refreshStatus(force: true)
        }
        model.onPermissions = { [weak self] in self?.requestPermissions() }
        model.onKeyboardSettings = { [weak self] in self?.openKeyboardSettings() }
        model.onLoginSettings = { [weak self] in self?.login.openSettings() }
        model.onRelaunch = { [weak self] in self?.relaunch() }
        model.onOpenApplications = { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications")) }
        model.onCopyDiagnostics = { [weak self] in
            guard let self else { return }
            self.refreshStatus(force: true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: self.lastStatusData, as: UTF8.self), forType: .string)
            self.showNotice("Диагностика скопирована")
        }
        model.onRestore = { [weak self] in self?.disableAndRestore() }
    }

    private func setFeature(_ key: String, _ enabled: Bool) {
        guard installed else { return }
        UserDefaults.standard.set(enabled, forKey: key)
        configurationDirty = true
        configurationError = ""
        lastActionError = ""
        supervisor.suspend(.sleeping)
        tick()
    }

    private func tick() {
        guard installed else { refreshStatus(); return }
        let previous = supervisor.state
        let suspended = sleeping || ProcessInfo.processInfo.systemUptime < resumeAt
        if fnEnabled {
            supervisor.tick(access: AXIsProcessTrusted() && CGPreflightListenEventAccess(),
                            secureInput: IsSecureEventInputEnabled(), suspended: suspended)
        } else {
            supervisor.suspend(.sleeping)
            let now = ProcessInfo.processInfo.systemUptime
            if configurationDirty && !suspended && now - lastConfigurationAttempt >= 2 {
                lastConfigurationAttempt = now
                do {
                    try settings.apply(fnEnabled: false, capsEnabled: capsEnabled)
                    didApplySettings = true
                    configurationDirty = false
                    configurationError = ""
                } catch { configurationError = error.localizedDescription }
            }
        }
        refreshStatus(force: previous != supervisor.state)
    }

    private func startMonitoring() throws {
        let actions = InputActions()
        let monitor = EventMonitor(statistics: statistics)
        monitor.onFailure = { [weak self] error in
            guard let self else { return }
            self.supervisor.restart(reason: error.localizedDescription)
            self.refreshStatus(force: true)
        }
        monitor.onSwitch = { [weak self] in self?.requestLanguageChange() }
        monitor.onChange = { [weak self] in self?.refreshStatus(force: true) }
        do {
            try monitor.start()
            try settings.apply(fnEnabled: true, capsEnabled: capsEnabled)
            didApplySettings = true
            configurationDirty = false
            configurationError = ""
        } catch { monitor.stop(); throw error }
        self.actions = actions
        self.monitor = monitor
    }

    private func stopMonitoring() {
        actions?.cancelPendingSwitches()
        monitor?.stop()
        monitor = nil
        actions = nil
    }

    private func requestLanguageChange() {
        guard supervisor.running, !IsSecureEventInputEnabled() else { return }
        actions?.switchLanguage { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.statistics.languageChanges += 1
                self.statistics.lastReason = "languageConfirmed"
                self.lastActionError = ""
            case .failure(let error):
                self.statistics.switchFailures += 1
                self.statistics.lastReason = "languageFailed"
                self.lastActionError = error.localizedDescription
            }
            self.refreshStatus(force: true)
        }
    }

    private var stateDescription: String {
        if !installed { return "Готово к установке" }
        if !fnEnabled { return capsEnabled ? "Caps Lock без задержки" : "Стандартные настройки" }
        switch supervisor.state {
        case .running: return lastActionError.isEmpty ? "Работает · Fn при отпускании" : "Не удалось сменить язык"
        case .waitingForAccess: return "Нужен доступ к клавиатуре"
        case .sleeping: return "Пауза · сон или смена сеанса"
        case .protectedInput: return "Пауза · защищённый ввод macOS"
        case .recovering: return "Восстановление обработчика Fn…"
        }
    }

    private var stateDetail: String {
        if !installed { return "Перемести приложение в «Программы» и запусти установленную копию." }
        if fnEnabled && IsSecureEventInputEnabled() { return "Обработка возобновится автоматически после завершения защищённого ввода." }
        if !fnEnabled { return capsEnabled ? "Fn работает средствами macOS. Задержка Caps Lock отключена." : "Исходное поведение клавиш восстановлено." }
        if !model.permissionsReady { return "Разреши доступ ниже. Программа проверит его и включит обработку Fn." }
        return "Одиночная Fn меняет язык после отпускания. Сочетания сохраняют обычное действие."
    }

    private var currentError: String {
        if !loginError.isEmpty { return loginError }
        if !configurationError.isEmpty { return configurationError }
        if case .recovering(let message) = supervisor.state { return message }
        return lastActionError
    }

    private func refreshStatus(force: Bool = false) {
        guard !preview else { return }
        model.fnEnabled = fnEnabled
        model.capsEnabled = capsEnabled
        model.showMenuBarIcon = showMenuBarIcon
        model.loginEnabled = login.enabled
        model.loginNeedsApproval = login.needsApproval
        model.loginDescription = login.description
        model.installationNeeded = !installed
        model.accessibility = AXIsProcessTrusted()
        model.inputMonitoring = CGPreflightListenEventAccess()
        model.status = stateDescription
        model.statusDetail = stateDetail
        model.running = supervisor.running || (!fnEnabled && capsEnabled && !configurationDirty)
        model.message = currentError
        model.fnHeld = statistics.lastReason == "fnPressed" && supervisor.running
        model.languageChanges = statistics.languageChanges
        model.chordsCancelled = statistics.chordsCancelled
        model.lastReason = statistics.lastReason
        model.capsLock = try? diagnosticActions.capsLockState()
        statusLine?.title = stateDescription
        statusItem?.button?.toolTip = stateDescription
        statusItem?.button?.appearsDisabled = !model.running
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastStatusWrite >= 1 else { return }
        lastStatusWrite = now
        var caps: Any = NSNull()
        if let value = model.capsLock { caps = value }
        let status: [String: Any] = [
            "version": "1.2.1", "minimumMacOS": "26.0", "testedMacOS": "27", "active": supervisor.running, "pid": getpid(),
            "fnEnabled": fnEnabled, "capsEnabled": capsEnabled, "loginEnabled": login.enabled,
            "showMenuBarIcon": showMenuBarIcon,
            "loginNeedsApproval": login.needsApproval, "state": stateDescription,
            "updatedAt": ISO8601DateFormatter().string(from: Date()), "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibility": model.accessibility, "inputMonitoring": model.inputMonitoring,
            "secureInput": IsSecureEventInputEnabled(), "monitorOpen": monitor?.isOpen ?? false,
            "fnElements": monitor?.fnElementCount ?? 0, "fnPresses": statistics.fnPresses, "fnReleases": statistics.fnReleases,
            "acceptedGestures": statistics.acceptedGestures, "chordsCancelled": statistics.chordsCancelled,
            "interruptedGestures": statistics.interruptedGestures, "languageChanges": statistics.languageChanges,
            "switchFailures": statistics.switchFailures, "monitorRestarts": supervisor.restarts,
            "lastRecovery": supervisor.lastRecovery, "lastReason": statistics.lastReason, "lastFnEventAt": statistics.lastFnEventAt,
            "capsLock": caps, "inputSource": InputActions.currentSourceID(), "error": currentError
        ]
        do {
            lastStatusData = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            if installed {
                try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
                try lastStatusData.write(to: supportDirectory.appendingPathComponent("status.json"), options: .atomic)
            }
        } catch { /* Diagnostic errors never interrupt keyboard handling. */ }
    }

    @objc private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = preview ? "ReleaseSwitch — предпросмотр" : "ReleaseSwitch"
            window.contentView = NSHostingView(rootView: AppSettingsView(model: model))
            window.minSize = NSSize(width: 575, height: 650)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) {
        model.testing = false
        if preview { NSApp.terminate(nil) }
    }
    @objc private func showKeyboardTest() { showWindow(); model.testing = true }

    @objc private func requestPermissions() {
        guard installed else { return }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    private func relaunch() {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundleURL.path, "--args", "--wait-for", String(getpid())]
            try process.run()
            NSApp.terminate(nil)
        } catch { configurationError = error.localizedDescription; refreshStatus(force: true) }
    }

    private func disableAndRestore() {
        supervisor.suspend(.sleeping)
        UserDefaults.standard.set(false, forKey: "fnEnabled")
        UserDefaults.standard.set(false, forKey: "capsEnabled")
        var errors: [String] = []
        do { try login.setEnabled(false) } catch { errors.append(error.localizedDescription) }
        do { try settings.restore(); didApplySettings = false; configurationDirty = false }
        catch { errors.append(error.localizedDescription); configurationDirty = true }
        configurationError = errors.joined(separator: "\n")
        loginError = ""
        lastActionError = ""
        showNotice(errors.isEmpty ? "Настройки восстановлены" : "Проверь настройки")
        refreshStatus(force: true)
    }

    private func showNotice(_ message: String) {
        model.notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.model.notice == message { self?.model.notice = "" }
        }
    }
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        guard didLaunch && !preview else { return }
        healthTimer?.invalidate()
        supervisor.suspend(.sleeping)
        if didApplySettings { try? settings.restore() }
        refreshStatus(force: true)
    }

    // An isolated, separately named build is used to inspect the window without
    // touching the installed app, its preferences, permissions, or login items.
    private func launchPreview() {
        model.status = previewMode == "setup" ? "Нужен доступ к клавиатуре" : "Работает · Fn при отпускании"
        model.statusDetail = "Одиночная Fn меняет язык после отпускания. Сочетания сохраняют обычное действие."
        model.running = previewMode != "setup"
        model.accessibility = model.running
        model.inputMonitoring = model.running
        model.loginEnabled = true
        if previewMode == "26" { model.majorVersion = 26 }
        model.onFnChanged = { [weak self] in self?.model.fnEnabled = $0 }
        model.onCapsChanged = { [weak self] in self?.model.capsEnabled = $0 }
        model.onMenuBarIconChanged = { [weak self] value in
            self?.model.showMenuBarIcon = value
            self?.statusItem?.isVisible = value
        }
        model.onLoginChanged = { [weak self] in self?.model.loginEnabled = $0 }
        model.onPermissions = { [weak self] in self?.model.accessibility = true; self?.model.inputMonitoring = true; self?.model.status = "Доступ выдан" }
        model.onCopyDiagnostics = { [weak self] in self?.showNotice("Диагностика скопирована") }
        model.onRestore = { [weak self] in self?.model.fnEnabled = false; self?.model.capsEnabled = false; self?.model.loginEnabled = false }
        createMenu()
        showWindow()
    }
}

if CommandLine.arguments.contains("--quit-running") {
    for instance in NSRunningApplication.runningApplications(withBundleIdentifier: "local.andrey.ReleaseSwitch") where instance.processIdentifier != getpid() {
        instance.terminate()
    }
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "local.andrey.ReleaseSwitch")
            .filter { $0.processIdentifier != getpid() }
        if instances.isEmpty { exit(0) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    fputs("Заверши прежнюю ReleaseSwitch через её меню и повтори установку.\n", stderr)
    exit(1)
}
if CommandLine.arguments.contains("--diagnostics") {
    print("version=1.2.1; minimumMacOS=26.0; testedMacOS=27")
    print("accessibility=\(AXIsProcessTrusted())")
    print("inputMonitoring=\(CGPreflightListenEventAccess())")
    print("secureInput=\(IsSecureEventInputEnabled())")
    print("inputSource=\(InputActions.currentSourceID())")
    do {
        print("availableSources=\(try InputActions.inputSources().count)")
        print("capsLock=\(try InputActions().capsLockState())")
        print("mappings=\(try KeyboardSettings().mappings())")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--restore") {
    do { try KeyboardSettings().restore(); print("Original keyboard settings restored.") }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--disable-login") {
    do { try LoginController().setEnabled(false) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
