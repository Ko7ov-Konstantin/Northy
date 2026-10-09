import AppKit
import SwiftUI

/// Окно настроек (⌘, в меню статус-бара). Обычное окно с заголовком — в нём
/// системные Picker и Toggle работают как везде, в отличие от панели у выреза.
/// Слева — список разделов, справа — содержимое выбранного.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case panel, tabs, limits, recording, clipboard, permissions, system, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .panel: "Панель"
            case .tabs: "Вкладки"
            case .limits: "Лимиты"
            case .recording: "Запись экрана"
            case .clipboard: "Буфер обмена"
            case .permissions: "Разрешения"
            case .system: "Система"
            case .about: "О программе"
            }
        }

        var icon: String {
            switch self {
            case .panel: "rectangle.topthird.inset.filled"
            case .tabs: "square.grid.2x2"
            case .limits: "gauge.with.dots.needle.50percent"
            case .recording: "record.circle"
            case .clipboard: "doc.on.clipboard"
            case .permissions: "lock.shield"
            case .system: "gearshape"
            case .about: "info.circle"
            }
        }
    }

    @State private var pane: Pane? = .panel

    @Bindable var settings: AppSettings
    var zaiKeys: ZaiKeyStore
    var glm: LimitsStore
    var tokenStore: TokenStatsStore
    let onZaiKeyChanged: () -> Void
    let onClearClipboard: () -> Void

    @State private var zaiKeyDraft = ""
    @State private var zaiKeyError: String?

    @State private var launchState = LaunchAtLogin.state
    @State private var launchError: String?
    @State private var clipboardCleared = false
    @State private var microphones: [AudioInput] = []
    @State private var permissionStates: [Permission: Permission.State] = [:]
    private let permissionChecks = PermissionChecks()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.icon)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            Form { detail }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 460)
        .onAppear {
            launchState = LaunchAtLogin.state
            microphones = ScreenRecorder.microphones()
        }
        .onChange(of: pane) { if pane == .permissions { refreshPermissions() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if pane == .permissions { refreshPermissions() }
        }
    }

    private var pricesStatus: (text: String, ok: Bool) {
        if tokenStore.priceFetchFailed { return ("Не удалось обновить цены — используются прежние", false) }
        guard let date = tokenStore.pricesFetchedAt else { return ("Используются встроенные цены", true) }
        let when = date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: "ru_RU")))
        let count = Formatting.plural(tokenStore.prices.count, ("модель", "модели", "моделей"))
        return ("Цены обновлены: \(when) · \(count)", true)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane ?? .panel {
        case .panel:
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
                Text("Панель можно растянуть за уголок справа снизу. ⌘1–⌘6 — вкладки по порядку, ⌘F — поиск в буфере, Esc — свернуть.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .tabs:
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
                Text("«Буфер» включён всегда. Без «Лимитов» Northy не обращается к claude.ai и Z.AI, а в строке меню вместо цифр — знак Northy. «Музыка» — сайт music.youtube.com внутри панели: вход в Google выполняется на его странице, Northy пароль не видит; при выключенной вкладке плеер закрывается.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .limits:
            Section("Что показывать") {
                Toggle("Лимиты Claude", isOn: limitsBlockBinding(.claudeLimits))
                Toggle("Лимиты GLM", isOn: limitsBlockBinding(.glmLimits))
                Text("Скрытый источник не запрашивается и пропадает из вкладки «Лимиты», меню и строки меню: без лимитов Claude Northy не обращается к claude.ai, а цифры в строке меню берутся из GLM. Остальные блоки вкладки настраиваются в ней самой — кнопкой «Настроить блоки» внизу.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Стоимость по ценам API") {
                HStack {
                    Button("Обновить цены") { Task { await tokenStore.refreshPricesNow() } }
                        .disabled(tokenStore.isFetchingPrices)
                    if tokenStore.isFetchingPrices { ProgressView().controlSize(.small) }
                }
                let price = pricesStatus
                Label(price.text, systemImage: price.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(price.ok ? .green : .orange)
                    .font(.callout)
                Text("Цены моделей Claude берутся из открытой таблицы LiteLLM раз в сутки. Если модели в таблице нет, используется встроенная цена.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Лимиты GLM (Z.AI)") {
                HStack {
                    SecureField("API-ключ Z.AI", text: $zaiKeyDraft, prompt: Text(zaiKeys.hasKey ? "Ключ сохранён" : "Вставьте ключ"))
                        .onSubmit(saveZaiKey)
                    Button("Сохранить", action: saveZaiKey)
                        .disabled(zaiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if zaiKeys.hasKey {
                        Button("Удалить", role: .destructive) {
                            zaiKeyDraft = ""
                            storeZaiKey("")
                        }
                    }
                }
                if let status = zaiKeyStatus {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.ok ? .green : .orange)
                        .font(.callout)
                }
                Text("Ключ тарифа GLM Coding Plan: лимиты запрашиваются вместе с лимитами Claude и видны во вкладке «Лимиты» и в меню. Ключ хранится в Связке ключей и уходит только на api.z.ai; после переустановки Northy macOS один раз спросит разрешение на доступ к нему.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .recording:
            Section("Запись экрана") {
                Toggle("Записывать звук системы", isOn: $settings.recordingAudio.systemSound)
                Picker("Микрофон", selection: $settings.recordingAudio.microphone) {
                    Text("Не записывать").tag(RecordingAudio.Microphone.none)
                    Text("По умолчанию").tag(RecordingAudio.Microphone.systemDefault)
                    ForEach(microphones) { Text($0.name).tag(RecordingAudio.Microphone.device($0.id)) }
                    if case .device(let id) = settings.recordingAudio.microphone, !microphones.contains(where: { $0.id == id }) {
                        Text("Отключённое устройство").tag(settings.recordingAudio.microphone)
                    }
                }
                Text("Звук системы и микрофон сводятся в одну дорожку. Для микрофона macOS один раз спросит разрешение.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .clipboard:
            Section("Буфер обмена") {
                Picker("Хранить в истории", selection: $settings.clipboardLimit) {
                    ForEach(AppSettings.clipboardLimits, id: \.self) { limit in
                        Text(Formatting.plural(limit, ("запись", "записи", "записей"))).tag(limit)
                    }
                }
                Picker("Закреплённых не больше", selection: $settings.pinLimit) {
                    ForEach(AppSettings.pinLimits, id: \.self) { limit in
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

        case .permissions:
            Section("Разрешения") {
                ForEach(Permission.allCases) { permission in
                    permissionRow(permission)
                }
                Text("Northy подписан упрощённой подписью, поэтому после обновления macOS может попросить часть разрешений заново.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

        case .system:
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

        case .about:
            Section("О программе") {
                LabeledContent("Northy", value: version)
                LabeledContent("Данные", value: AppData.directory.path)
                    .textSelection(.enabled)
            }
        }
    }
}

extension SettingsView {
    fileprivate func refreshPermissions() {
        permissionStates = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.state(permissionChecks)) })
    }

    @ViewBuilder
    fileprivate func permissionRow(_ permission: Permission) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(permission.title)
                Spacer()
                switch permissionStates[permission] ?? .notChecked {
                case .granted:
                    Label("Выдано", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Label("Не выдано", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .unknown:
                    Label("Неизвестно", systemImage: "questionmark.circle.fill").foregroundStyle(.secondary)
                case .notChecked:
                    EmptyView()
                }
                if permission.hasSettingsAction {
                    Button("Открыть настройки") { permission.openSettings(permissionChecks) }
                }
            }
            Text(permission.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Итог проверки ключа: ошибка сохранения, ответ Z.AI или найденный тариф.
    fileprivate var zaiKeyStatus: (text: String, ok: Bool)? {
        if let zaiKeyError { return (zaiKeyError, false) }
        guard zaiKeys.hasKey else { return nil }
        if glm.isLoading { return nil }
        if let error = glm.errorMessage { return (error, false) }
        guard let snapshot = glm.snapshot else { return nil }
        return (snapshot.plan.map { "Ключ принят · тариф \($0)" } ?? "Ключ принят", true)
    }

    fileprivate func limitsBlockBinding(_ block: LimitsBlock) -> Binding<Bool> {
        Binding(
            get: { settings.limitsBlocks.contains(block) },
            set: { isOn in
                if isOn {
                    // Лимиты встают в начало, как по умолчанию: Claude первым, GLM следом.
                    let index = block == .claudeLimits ? 0 : (settings.limitsBlocks.first == .claudeLimits ? 1 : 0)
                    settings.limitsBlocks = LimitsBlock.placing(block, at: index, in: settings.limitsBlocks)
                } else {
                    settings.limitsBlocks.removeAll { $0 == block }
                }
            }
        )
    }

    fileprivate func saveZaiKey() {
        guard !zaiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        storeZaiKey(zaiKeyDraft)
    }

    fileprivate func storeZaiKey(_ value: String) {
        do {
            try zaiKeys.save(value)
            zaiKeyDraft = ""
            zaiKeyError = nil
            onZaiKeyChanged()
        } catch {
            zaiKeyError = error.localizedDescription
        }
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
            // Окно открывается на текущем рабочем столе, а не уводит на тот, где его оставили.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            self.window = window
        }
        // NSApp.activate() — лишь просьба: из меню строки состояния, пока активно чужое
        // приложение, macOS её не исполняет, и окно остаётся позади без фокуса.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
