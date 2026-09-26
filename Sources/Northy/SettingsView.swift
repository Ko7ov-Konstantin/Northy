import AppKit
import SwiftUI

/// Окно настроек (⌘, в меню статус-бара). Обычное окно с заголовком — в нём
/// системные Picker и Toggle работают как везде, в отличие от панели у выреза.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let onClearClipboard: () -> Void

    @State private var launchState = LaunchAtLogin.state
    @State private var launchError: String?
    @State private var clipboardCleared = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Панель") {
                Picker("Горячая клавиша", selection: $settings.hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0) }
                }
                if let problem = settings.hotKeyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Toggle("Открывать при наведении на вырез", isOn: $settings.openOnHover)
                Text("Панель можно растянуть за уголок справа снизу. ⌘1–⌘4 — вкладки по порядку, ⌘F — поиск в буфере, Esc — свернуть.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Вкладки") {
                ForEach(PanelTab.allCases) { tab in
                    Toggle(isOn: Binding(
                        get: { settings.enabledTabs.contains(tab) },
                        set: { isOn in
                            if isOn { settings.enabledTabs.insert(tab) } else { settings.enabledTabs.remove(tab) }
                        }
                    )) {
                        Label(tab.title, systemImage: tab.icon)
                    }
                    .disabled(tab == .clipboard)
                }
                Text("«Буфер» включён всегда. Без «Лимитов» кольца пропадают из шапки, в строке меню лимиты остаются.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Буфер обмена") {
                Picker("Хранить в истории", selection: $settings.clipboardLimit) {
                    ForEach(AppSettings.clipboardLimits, id: \.self) { limit in
                        Text(Formatting.plural(limit, ("запись", "записи", "записей"))).tag(limit)
                    }
                }
                Text("Закреплённые записи хранятся сверх лимита и не удаляются при очистке.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(clipboardCleared ? "Очищено" : "Очистить историю") {
                        onClearClipboard()
                        clipboardCleared = true
                    }
                    .disabled(clipboardCleared)
                    Spacer()
                    Button("Показать папку данных") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppData.directory])
                    }
                }
            }

            Section("Система") {
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { launchState.isOn },
                    set: { enabled in
                        let result = LaunchAtLogin.set(enabled)
                        launchState = result.0
                        launchError = result.1
                    }
                ))
                if let hint = launchError ?? launchState.hint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Northy", value: version)
                LabeledContent("Данные", value: AppData.directory.path)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchState = LaunchAtLogin.state }
    }
}

/// Окно настроек создаётся один раз и переиспользуется.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeView: () -> SettingsView

    init(makeView: @escaping () -> SettingsView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Настройки Northy"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // Accessory-приложение без активации покажет окно позади остальных.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
