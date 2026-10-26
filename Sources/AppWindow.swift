import AppKit
import SwiftUI

final class AppViewModel: ObservableObject {
    @Published var fnEnabled = true
    @Published var capsEnabled = true
    @Published var showMenuBarIcon = true
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var loginDescription = "Запускать программу вместе с системой."
    @Published var status = "Подготовка…"
    @Published var statusDetail = "Проверяем настройки клавиатуры."
    @Published var running = false
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var message = ""
    @Published var notice = ""
    @Published var installationNeeded = false
    @Published var testing = false
    @Published var fnHeld = false
    @Published var capsLock: Bool?
    @Published var languageChanges = 0
    @Published var chordsCancelled = 0
    @Published var lastReason = ""
    @Published var testText = ""
    var initialTestChanges = 0
    var initialTestChords = 0
    var onFnChanged: ((Bool) -> Void)?
    var onCapsChanged: ((Bool) -> Void)?
    var onMenuBarIconChanged: ((Bool) -> Void)?
    var onLoginChanged: ((Bool) -> Void)?
    var onPermissions: (() -> Void)?
    var onKeyboardSettings: (() -> Void)?
    var onLoginSettings: (() -> Void)?
    var onRelaunch: (() -> Void)?
    var onOpenApplications: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    var onRestore: (() -> Void)?
    var permissionsReady: Bool { accessibility && inputMonitoring }
    var majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var accessName: String { majorVersion >= 27 ? "Управление устройством и доступ к данным" : "Универсальный доступ" }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct AppSettingsView: View {
    @ObservedObject var model: AppViewModel
    private let accent = Color(red: 0.20, green: 0.39, blue: 0.83)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 15) {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ReleaseSwitch").font(.system(size: 27, weight: .semibold, design: .rounded))
                        Text("Fn при отпускании. Caps Lock без задержки.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(.bottom, 3)

                SettingsCard {
                    HStack(spacing: 10) {
                        Circle().fill(model.running ? Color.green : Color.orange).frame(width: 9, height: 9)
                        Text(model.status).font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }
                    Text(model.statusDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.majorVersion == 26 {
                    Label("macOS 26 не тестировалась. Возможны сбои. Программа проверена на macOS 27.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if model.installationNeeded {
                    SettingsCard {
                        Label("Сначала перенеси приложение в «Программы»", systemImage: "folder.badge.plus")
                            .font(.headline)
                        Text("Перетащи ReleaseSwitch на папку «Программы» в окне DMG, затем запусти установленную копию.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Button("Открыть «Программы»") { model.onOpenApplications?() }
                    }
                }

                SettingsCard {
                    HStack {
                        Label("Доступ к клавиатуре", systemImage: model.permissionsReady ? "checkmark.shield.fill" : "lock.shield")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if model.permissionsReady { Text("Выдан").font(.system(size: 12)).foregroundStyle(.green) }
                    }
                    if !model.permissionsReady {
                        permissionRow(model.accessName, ready: model.accessibility)
                        permissionRow("Мониторинг ввода", ready: model.inputMonitoring)
                    }
                    Text("Доступ нужен для Fn и распознавания сочетаний. Вводимый текст и история нажатий не сохраняются.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(model.permissionsReady ? "Настройки доступа…" : "Разрешить доступ…") { model.onPermissions?() }
                            .buttonStyle(.borderedProminent)
                        if model.accessibility && !model.inputMonitoring {
                            Button("Перезапустить приложение") { model.onRelaunch?() }
                        }
                    }.disabled(model.installationNeeded)
                }

                SettingsCard {
                    option("Fn / 🌐", subtitle: "Менять язык при отпускании, без ограничения удержания.",
                           symbol: "globe", value: Binding(get: { model.fnEnabled }, set: { model.onFnChanged?($0) }))
                    HStack {
                        Text(model.fnEnabled ? "Для одиночной 🌐 выбери «Действие не требуется»." : "Действие Fn можно выбрать в настройках macOS.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Настроить…") { model.onKeyboardSettings?() }.font(.system(size: 11))
                    }
                    Divider()
                    option("Caps Lock", subtitle: "Убрать задержку включения ЗАГЛАВНЫХ букв.",
                           symbol: "capslock.fill", value: Binding(get: { model.capsEnabled }, set: { model.onCapsChanged?($0) }))
                    Divider()
                    option("Запускать при входе", subtitle: model.loginDescription,
                           symbol: "power", value: Binding(get: { model.loginEnabled }, set: { model.onLoginChanged?($0) }))
                    if model.loginNeedsApproval {
                        Button("Разрешить автозапуск в настройках…") { model.onLoginSettings?() }
                    }
                    Divider()
                    option("Показывать в строке меню", subtitle: "Если значок скрыт, открыть окно можно из «Программ».",
                           symbol: "menubar.rectangle", value: Binding(get: { model.showMenuBarIcon }, set: { model.onMenuBarIconChanged?($0) }))
                }.disabled(model.installationNeeded)

                if !model.message.isEmpty {
                    Label(model.message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Проверить клавиши") { model.testing = true }
                    Button("Скопировать диагностику") { model.onCopyDiagnostics?() }
                    Spacer()
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Silicon · macOS 26+").font(.system(size: 11, weight: .medium))
                        Text("Проверено на macOS 27. На macOS 26 возможны сбои.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Версия 1.2.1").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Отключить и восстановить настройки") { model.onRestore?() }
                        .buttonStyle(.link).font(.system(size: 11))
                    Spacer()
                    Text(model.notice).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("После закрытия окна программа продолжает работать. Открыть окно снова можно из «Программ».")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .frame(minWidth: 560, minHeight: 620)
        .sheet(isPresented: $model.testing) { KeyboardTestView(model: model) }
    }

    private func permissionRow(_ title: String, ready: Bool) -> some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Color.green : Color.secondary)
            Text(title).font(.system(size: 12))
            Spacer()
        }
    }
    private func option(_ title: String, subtitle: String, symbol: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(accent).frame(width: 27)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).accessibilityLabel(title)
        }
    }
}

private struct KeyboardTestView: View {
    @ObservedObject var model: AppViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Проверка клавиш").font(.system(size: 22, weight: .semibold))
            Text("Проверь быстрые и долгие нажатия. Язык должен меняться один раз, после отпускания Fn.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            SettingsCard {
                Label(!model.fnEnabled ? "Fn отключена" : (model.fnHeld ? "Fn нажата — отпусти клавишу" : "Fn готова к проверке"), systemImage: "globe")
                    .font(.headline).foregroundStyle(model.fnHeld ? Color.accentColor : Color.primary)
                Text("Подтверждённых смен языка: \(max(0, model.languageChanges - model.initialTestChanges))")
                Text("Отменено сочетаний: \(max(0, model.chordsCancelled - model.initialTestChords))")
                Text("Fn + Shift и Fn + стрелки не должны менять язык.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            SettingsCard {
                Label("Caps Lock: \(model.capsLock == true ? "включён" : "выключен")", systemImage: "capslock.fill")
                    .font(.headline)
                Text("Нажми Caps Lock, проверь индикатор и набери текст. Повторное нажатие должно выключить заглавные.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Текст для проверки Caps Lock", text: $model.testText).textFieldStyle(.roundedBorder)
                Text("Текст удаляется при закрытии проверки.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Готово") { model.testText = ""; model.testing = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 490)
        .onAppear { model.initialTestChanges = model.languageChanges; model.initialTestChords = model.chordsCancelled }
        .onDisappear { model.testText = "" }
    }
}
