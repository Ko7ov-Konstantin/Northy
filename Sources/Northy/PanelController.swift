import AppKit
import SwiftUI

/// Общее UI-состояние панели, разделяемое между AppKit (геометрия окна)
/// и SwiftUI (анимация содержимого).
@MainActor
@Observable
final class PanelUIState {
    var isExpanded = false
    /// Каждое раскрытие панели начинается с «Буфера» (перетаскивание файла — с «Файлов»).
    var selectedTab: PanelTab = .clipboard
    /// Высота выреза — отступ сверху, ниже которого начинается читаемый контент.
    var topInset: CGFloat = 0
    /// Ширина выреза — промежуток в шапке между вкладками и действиями.
    var notchWidth: CGFloat = 0
    /// Размеры «острова» в двух состояниях — между ними анимируется форма.
    var collapsedSize: CGSize = NotchGeometry.fallbackSize
    var expandedSize: CGSize = NotchGeometry.expandedContentSize
    /// Над панелью тащат файл — показывается рамка «отпустите здесь».
    var isDropTargeted = false
    /// Панель растягивают за уголок — сворачивать её в этот момент нельзя.
    var isResizing = false
    /// Поиск во вкладке «Буфер»; Escape сначала очищает его, потом сворачивает панель.
    var clipboardQuery = ""
    /// Меняется по ⌘F — вкладка «Буфер» ставит фокус в поле поиска.
    var searchFocusRequest = 0
    /// Запрошенный размер содержимого при перетаскивании уголка; окно подстраивает контроллер.
    @ObservationIgnored var onResize: ((CGSize) -> Void)?
    @ObservationIgnored var onResizeEnded: (() -> Void)?
    @ObservationIgnored var onOpenSettings: (() -> Void)?
}

/// Рекурсивно снимает регистрацию dragged types у вью и всех его потомков.
/// SwiftUI-контент содержит AppKit-вью, которые сами регистрируются на драг
/// (в первую очередь NSTextView внутри TextEditor переводчика) — в глубине
/// дерева они перехватывают drag-сессию у DropContainerView раньше, чем
/// курсор доходит до дна панели. Дёшево — вызывается при старте и при каждом
/// развороте, поскольку SwiftUI может домонтировать такие вью лениво.
private extension NSView {
    func unregisterDraggedTypesRecursively() {
        unregisterDraggedTypes()
        for subview in subviews {
            subview.unregisterDraggedTypesRecursively()
        }
    }
}

/// NSHostingView, которая ловит mouseEntered/mouseExited через NSTrackingArea.
final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

@MainActor
final class PanelController: NSObject {

    private var panel: NotchPanel!
    private var hostingView: NSView!
    private var limitsCard: NSView?
    let uiState = PanelUIState()
    let clipboardStore = ClipboardStore()
    let shelfStore = ShelfStore()
    let limitsStore = LimitsStore(source: ClaudeWebLimitsSource(), history: UsageHistory())
    let tokenStore = TokenStatsStore()
    let settings = AppSettings()
    private let hotKey = GlobalHotKey()
    private lazy var settingsWindow = SettingsWindowController { [unowned self] in
        SettingsView(settings: settings) { [weak self] in self?.clipboardStore.clear() }
    }

    private var collapseWorkItem: DispatchWorkItem?
    /// Отложенный старт анимации раскрытия отменяется свёртыванием, случившимся раньше.
    private var expandGeneration = 0
    private var expandWorkItem: DispatchWorkItem?
    private var dragMonitor: Any?
    private var statusItem: NSStatusItem?
    private static let collapseDelay: TimeInterval = 0.35
    /// Пауза перед разворотом по наведению: курсор, идущий к пунктам меню-бара
    /// мимо выреза, не должен раскрывать панель на пол-экрана.
    private static let expandDelay: TimeInterval = 0.2
    private static let collapseAnimationDuration: TimeInterval = 0.32
    private static let focusRecheckDelay: TimeInterval = 1.0

    /// Вызывается при завершении приложения: debounced-записи — на диск.
    func flushStores() {
        clipboardStore.flush()
        shelfStore.flush()
        limitsStore.history?.flush()
        // Без Northy пункты Finder не нужны: без файла состояния расширение их не покажет.
        try? FileManager.default.removeItem(at: finderStateURL)
    }

    func start() {
        clipboardStore.start()
        updateGeometry()

        let collapsedFrame = NotchGeometry.collapsedFrame()
        panel = NotchPanel(contentRect: collapsedFrame)
        // Панель всегда тёмная, включая NSTextView под TextEditor (курсор, выделение).
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onEscape = { [weak self] in self?.handleEscape() }
        panel.onTabShortcut = { [weak self] number in
            guard let self, number <= PanelTab.allCases.count else { return }
            withAnimation(Theme.tabSpring) { self.uiState.selectedTab = PanelTab.allCases[number - 1] }
        }
        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.onFind = { [weak self] in
            guard let self else { return }
            withAnimation(Theme.tabSpring) { self.uiState.selectedTab = .clipboard }
            self.uiState.searchFocusRequest += 1
        }
        uiState.onResize = { [weak self] size in self?.resizePanel(to: size) }
        uiState.onResizeEnded = { [weak self] in self?.finishResize() }
        uiState.onOpenSettings = { [weak self] in self?.openSettings() }

        let rootView = PanelRootView(
            uiState: uiState,
            clipboardStore: clipboardStore,
            shelfStore: shelfStore,
            limitsStore: limitsStore,
            tokenStore: tokenStore
        )
        let hostingView = TrackingHostingView(rootView: rootView)
        hostingView.onMouseEntered = { [weak self] in self?.handleMouseEntered() }
        hostingView.onMouseExited = { [weak self] in self?.handleMouseExited() }
        self.hostingView = hostingView

        // DropContainerView — прозрачный для кликов оверлей ПОВЕРХ hostingView (не
        // контейнер под ним): в глубине SwiftUI-дерева живут AppKit-вью (NSTextView
        // и т.п.), которые сами регистрируются на драг и в нижней части панели
        // перехватывали drag-сессию раньше нашего вью. hitTest у оверлея возвращает
        // nil, поэтому клики/жесты проходят насквозь к SwiftUI как раньше.
        let rootContainer = NSView(frame: CGRect(origin: .zero, size: collapsedFrame.size))

        hostingView.frame = rootContainer.bounds
        hostingView.autoresizingMask = [.width, .height]
        rootContainer.addSubview(hostingView)

        let dropOverlay = DropContainerView(frame: rootContainer.bounds)
        dropOverlay.autoresizingMask = [.width, .height]
        dropOverlay.onFileURLs = { [weak self] urls in
            withAnimation(Theme.tabSpring) {
                self?.shelfStore.add(urls)
                self?.uiState.selectedTab = .files
            }
        }
        dropOverlay.onTargetingChanged = { [weak self] isTargeted in
            self?.uiState.isDropTargeted = isTargeted
        }
        rootContainer.addSubview(dropOverlay, positioned: .above, relativeTo: hostingView)
        panel.contentView = rootContainer

        hostingView.unregisterDraggedTypesRecursively()

        panel.setFrame(collapsedFrame, display: true)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Клик в другое приложение снимает key у панели — если мышь при этом уже вне
        // панели, сворачиваем сразу, не дожидаясь старого таймера mouseExited.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )

        // NSTrackingArea не шлёт mouseEntered/mouseExited во время drag-сессии
        // (macOS-ограничение), поэтому наведение перетаскиваемого файла на свёрнутый
        // вырез ловим глобальным монитором мыши — он не требует Accessibility (в отличие
        // от клавиатурных событий). mouseUp в том же мониторе ловит конец drag-сессии:
        // без него drag, отменённый вне панели, оставлял панель развёрнутой навсегда.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Мониторы доставляют события в main-потоке — assumeIsolated вместо
            // Task-хопа убирает аллокацию на каждое событие мыши во всей системе.
            MainActor.assumeIsolated {
                self?.handleDragMonitorEvent(event)
            }
        }

        installStatusItem()

        hotKey.onPress = { [weak self] in self?.toggleFromHotKey() }
        observeHotKeySetting()
        observeClipboardLimit()
        startFinderBridge()
    }

    // Иконка в статус-баре — точка входа в приложение, если панель недоступна
    // (например, свернулась на отключившемся экране).
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self

        // Карточка лимитов, как у CodexBar: SwiftUI-вью прямо в меню, следит за LimitsStore сама.
        let card = NSHostingView(rootView: LimitsMenuCard(store: limitsStore, tokens: tokenStore))
        card.sizingOptions = [.intrinsicContentSize]
        card.frame.size = card.fittingSize
        limitsCard = card
        let cardItem = NSMenuItem()
        cardItem.view = card
        // Наведение на карточку раскрывает график стоимости сбоку — как у CodexBar.
        let cardTokens = tokenStore
        cardItem.submenu = chartSubmenu {
            DailyUsageChart(stats: cardTokens.stats(for: nil))
        }
        menu.addItem(cardItem)
        menu.addItem(.separator())

        // Подменю с графиками, как у CodexBar: история плана и стоимость по дням.
        let history = limitsStore.history
        menu.addItem(chartSubmenuItem(title: "Использование плана", symbol: "chart.bar.xaxis") {
            PlanHistoryChart(samples: history?.samples ?? [])
        })
        let tokens = tokenStore
        menu.addItem(chartSubmenuItem(title: "Стоимость", symbol: "dollarsign.circle") {
            DailyUsageChart(stats: tokens.stats(for: nil))
        })
        menu.addItem(chartSubmenuItem(title: "Сессии Claude Code", symbol: "terminal") {
            ClaudeSessionsList(sessions: tokens.sessions, limit: 10)
        })
        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Показать панель", action: #selector(showPanelFromStatusMenu), keyEquivalent: "")
        showItem.target = self
        showItem.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: nil)
        menu.addItem(showItem)
        // Пункт с собственным видом: клик по нему не закрывает меню — данные
        // обновляются прямо в открытой карточке. ⌘R работает как обычно.
        let refreshItem = NSMenuItem(title: "Обновить", action: #selector(refreshFromStatusMenu), keyEquivalent: "r")
        refreshItem.target = self
        let refreshRow = NSHostingView(rootView: RefreshMenuRow(limits: limitsStore, tokens: tokenStore) { [weak self] in
            self?.refreshEverything(force: true)
        })
        refreshRow.frame.size = refreshRow.fittingSize
        refreshItem.view = refreshRow
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        let dashboardItem = NSMenuItem(title: "Дашборд использования", action: #selector(openLinkFromStatusMenu(_:)), keyEquivalent: "")
        dashboardItem.target = self
        dashboardItem.representedObject = URL(string: "https://claude.ai/settings/usage")
        dashboardItem.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil)
        menu.addItem(dashboardItem)

        // Подменю со статусом сервисов Claude — как у CodexBar; заполняется при открытии меню.
        let statusPageItem = NSMenuItem(title: "Страница статуса", action: nil, keyEquivalent: "")
        statusPageItem.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        statusPageItem.submenu = statusSubmenu
        menu.addItem(statusPageItem)
        statusSubmenu.delegate = self
        fillStatusSubmenu()
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: "Выход", action: #selector(quitFromStatusMenu), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
        observeLimits()
    }

    /// Значок в строке меню — следом за LimitsStore.
    private func observeLimits() {
        withObservationTracking {
            updateStatusButton(lines: limitsStore.snapshot?.statusBarLines ?? [])
            // Высота карточки меняется вместе с данными (строки лимитов, ошибка, загрузка).
            _ = limitsStore.errorMessage
            _ = limitsStore.isLoading
            _ = tokenStore.rows
            _ = tokenStore.isScanning
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.observeLimits()
                self?.resizeMenuViews()
            }
        }
    }

    /// NSMenu не пересчитывает высоту view-пункта сам — без этого карточка,
    /// созданная пустой, показывала лишь нижнюю строку.
    private func resizeMenuViews() {
        for view in [limitsCard].compactMap({ $0 }) + hostedMenuViews {
            view.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            if view.frame.size != size { view.setFrameSize(size) }
        }
    }

    private func updateStatusButton(lines: [String]) {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.image = Self.statusImage(lines: lines)
        statusItem?.length = lines.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }

    /// Иконка и строки остатка друг под другом (как у CodexBar). Шаблонная
    /// картинка — цвет подстраивается под светлую и тёмную строку меню.
    private static func statusImage(lines: [String]) -> NSImage? {
        let icon = NSImage(systemSymbolName: "sparkle.rectangle.tophalf.inset.filled", accessibilityDescription: "Northy")
        guard !lines.isEmpty else { return icon }

        let symbol = icon?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let texts = lines.prefix(2).map { NSAttributedString(string: $0, attributes: attributes) }
        let textWidth = ceil(texts.map { $0.size().width }.max() ?? 0)
        let iconWidth = ceil(symbol?.size.width ?? 0)
        let gap: CGFloat = symbol == nil ? 0 : 4
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: iconWidth + gap + textWidth, height: height), flipped: false) { rect in
            if let symbol {
                let y = (rect.height - symbol.size.height) / 2
                symbol.draw(in: NSRect(x: 0, y: y, width: symbol.size.width, height: symbol.size.height))
            }
            let lineHeight = texts.first?.size().height ?? 11
            let top = texts.count == 1 ? (rect.height - lineHeight) / 2 : rect.height / 2 - 1
            for (index, text) in texts.enumerated() {
                text.draw(at: NSPoint(x: iconWidth + gap, y: top - CGFloat(index) * (lineHeight - 1.5)))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private let statusSubmenu = NSMenu()
    /// SwiftUI-вью внутри меню и подменю: NSMenu сам их высоту не пересчитывает.
    private var hostedMenuViews: [NSView] = []

    /// Пункт с подменю, внутри которого — SwiftUI-график. Замыкание читает
    /// наблюдаемые сторы, поэтому график обновляется вместе с данными.
    private func chartSubmenuItem<Content: View>(title: String, symbol: String, @ViewBuilder content: @escaping () -> Content) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.submenu = chartSubmenu(content: content)
        return item
    }

    private func chartSubmenu<Content: View>(@ViewBuilder content: @escaping () -> Content) -> NSMenu {
        let host = NSHostingView(rootView: ChartMenuContainer(content: content))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame.size = host.fittingSize
        hostedMenuViews.append(host)

        let submenu = NSMenu()
        submenu.delegate = self
        let viewItem = NSMenuItem()
        viewItem.view = host
        submenu.addItem(viewItem)
        return submenu
    }

    /// Последние полученные статусы и их свежесть — при ошибке список не пропадает.
    private var statusComponents: [StatusPage.Component]?
    private var statusUpdatedAt: Date?
    private var statusLoading = false
    private var statusFailed = false

    private func fillStatusSubmenu() {
        statusSubmenu.removeAllItems()
        let freshness = NSMenuItem(
            title: StatusPage.freshness(updatedAt: statusUpdatedAt, isLoading: statusLoading, failed: statusFailed),
            action: nil,
            keyEquivalent: ""
        )
        freshness.isEnabled = false
        freshness.image = NSImage(
            systemSymbolName: statusFailed ? "exclamationmark.triangle" : "clock",
            accessibilityDescription: nil
        )
        statusSubmenu.addItem(freshness)
        statusSubmenu.addItem(.separator())
        if let components = statusComponents {
            // Табуляция с правым выравниванием — статус прижат к правому краю, как у CodexBar.
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 320)]
            for component in components {
                let title = NSMutableAttributedString(
                    string: "● ",
                    attributes: [.foregroundColor: component.status.color, .font: NSFont.menuFont(ofSize: 0)]
                )
                title.append(NSAttributedString(string: component.name, attributes: [.font: NSFont.menuFont(ofSize: 0)]))
                title.append(NSAttributedString(
                    string: "\t\(component.status.title)",
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
                ))
                title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
                let item = NSMenuItem(title: component.name, action: #selector(openLinkFromStatusMenu(_:)), keyEquivalent: "")
                item.attributedTitle = title
                item.target = self
                item.representedObject = StatusPage.pageURL
                statusSubmenu.addItem(item)
            }
            statusSubmenu.addItem(.separator())
        }
        let openItem = NSMenuItem(title: "Открыть страницу статуса", action: #selector(openLinkFromStatusMenu(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = StatusPage.pageURL
        openItem.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        statusSubmenu.addItem(openItem)
    }

    private func refreshStatusPage() {
        guard !statusLoading else { return }
        statusLoading = true
        fillStatusSubmenu()
        Task {
            do {
                statusComponents = try await StatusPage.fetch()
                statusUpdatedAt = .now
                statusFailed = false
            } catch {
                statusFailed = true
            }
            statusLoading = false
            fillStatusSubmenu()
        }
    }

    @objc private func openLinkFromStatusMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings() {
        collapse()
        settingsWindow.show()
    }

    @objc private func refreshFromStatusMenu() {
        refreshEverything(force: true)
    }

    /// Лимиты, токены по логам и статус сервисов. force — мимо минутного
    /// ограничения сканера логов (кнопка «Обновить»).
    private func refreshEverything(force: Bool) {
        Task { await limitsStore.refresh(force: true) }
        Task { await tokenStore.refresh(force: force) }
        refreshStatusPage()
    }

    /// Лимиты обновляются только по открытию панели или меню, без фонового опроса.
    private func refreshLimits() {
        Task { await limitsStore.refresh() }
        Task { await tokenStore.refresh() }
    }

    @objc private func showPanelFromStatusMenu() {
        panel.orderFrontRegardless()
        expand()
        // Явное действие пользователя — здесь фокус взять уместно.
        panel.makeKey()
    }

    @objc private func quitFromStatusMenu() {
        NSApp.terminate(nil)
    }

    private func handleDragMonitorEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            // Drag закончился (дроп или отмена). Если мышь вне панели — проверяем
            // сворачивание: mouseExited во время drag-сессии не приходил.
            if uiState.isExpanded, !panel.frame.contains(NSEvent.mouseLocation) {
                scheduleCollapseCheck(after: Self.collapseDelay)
            }
            return
        }

        guard !uiState.isExpanded else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        guard NotchGeometry.collapsedFrame().contains(NSEvent.mouseLocation) else { return }

        handleDragEntered()
        // Перерегистрация окна сразу после ресайза по drag-монитору — подстраховка
        // на случай отставания window server от setFrame во время активной drag-сессии.
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    /// Регистрирует сочетание из настроек и перерегистрирует при его смене.
    private func observeHotKeySetting() {
        withObservationTracking {
            let preset = settings.hotKey
            switch hotKey.register(preset) {
            case .success:
                settings.hotKeyProblem = nil
            case .failure(.taken):
                settings.hotKeyProblem = "Сочетание \(preset.title) уже занято другим приложением — выберите другое"
            case .failure(.failed(let status)):
                settings.hotKeyProblem = "Не удалось назначить \(preset.title) (код \(status))"
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeHotKeySetting() }
        }
    }

    /// Размер истории буфера из настроек — применяется сразу, лишние старые записи срезаются.
    private func observeClipboardLimit() {
        // Под наблюдением — только настройка: сам стор при смене лимита читает
        // историю, и слежка срабатывала бы на каждое копирование.
        let limit = withObservationTracking {
            settings.clipboardLimit
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeClipboardLimit() }
        }
        clipboardStore.limit = limit
    }

    // MARK: - Мост с расширением Finder

    /// Секрет живёт до выхода из приложения; при каждом запуске — новый.
    private let finderToken = FinderBridge.makeToken()
    private var finderStateURL: URL { AppData.directory.appendingPathComponent(FinderBridge.stateFilename) }

    private func startFinderBridge() {
        observeShelfForFinder()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleFinderRequest(_:)),
            name: FinderBridge.requestNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    /// Свежие файлы полки (с датами) — в файл состояния для расширения.
    private func observeShelfForFinder() {
        let recent = withObservationTracking {
            shelfStore.recentFiles(window: FinderBridge.recentWindow).compactMap { url in
                shelfStore.addedAt(url).map { (url: url, addedAt: $0) }
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeShelfForFinder() }
        }
        do {
            try FinderBridge.writeState(token: finderToken, recent: recent, to: finderStateURL)
        } catch {
            NSLog("[Northy] finder bridge state write failed: %@", error.localizedDescription)
        }
    }

    @objc private func handleFinderRequest(_ notification: Notification) {
        guard let json = notification.object as? String,
              let request = FinderBridge.parseRequest(json, token: finderToken)
        else { return }
        switch request {
        case .send(let urls):
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else {
                NSSound.beep()
                return
            }
            withAnimation(Theme.tabSpring) { shelfStore.add(existing) }
            showShelfBriefly()
        case .paste(let directory):
            let files = shelfStore.recentFiles(window: FinderBridge.recentWindow)
            guard !files.isEmpty else {
                NSSound.beep()
                return
            }
            // Копирование больших файлов — не на главном потоке.
            Task.detached(priority: .userInitiated) {
                do {
                    _ = try FinderBridge.paste(files, into: directory)
                } catch {
                    await MainActor.run { NSSound.beep() }
                }
            }
        }
    }

    /// Файл отправлен из Finder — полка на пару секунд показывает, что он на месте.
    private func showShelfBriefly() {
        let wasExpanded = uiState.isExpanded
        if !wasExpanded {
            panel.orderFrontRegardless()
            expand()
        }
        withAnimation(Theme.tabSpring) { uiState.selectedTab = .files }
        guard !wasExpanded else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.uiState.isExpanded, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.collapse()
        }
    }

    /// Клавиша — явное действие: панель раскрывается и берёт фокус ввода
    /// (как «Показать панель» из меню); повторное нажатие сворачивает.
    private func toggleFromHotKey() {
        if uiState.isExpanded {
            collapse()
        } else {
            panel.orderFrontRegardless()
            expand()
            panel.makeKey()
        }
    }

    private func handleMouseEntered() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        guard !uiState.isExpanded, settings.openOnHover else { return }
        // Разворот с короткой паузой (dwell): быстрый проход курсора мимо
        // выреза по пути к меню-бару панель не раскрывает.
        expandWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.expand() }
        expandWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandDelay, execute: item)
    }

    /// Тот же путь, что при hover, плюс переключение на вкладку «Файлы» —
    /// чтобы перетащенный файл сразу стало видно на полке.
    private func handleDragEntered() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        expandWorkItem?.cancel()
        expandWorkItem = nil
        if !uiState.isExpanded {
            expand()
        }
        withAnimation(Theme.tabSpring) {
            uiState.selectedTab = .files
        }
    }

    private func expand() {
        // Окно сразу принимает полный размер (прозрачное), а форма «острова»
        // внутри анимированно вырастает из выреза.
        // Раскладка под новый размер окна — сразу и без анимации: иначе SwiftUI
        // берёт старую позицию (левый угол маленького окна) за старт роста.
        panel.setFrame(NotchGeometry.expandedFrame(), display: true)
        uiState.selectedTab = .clipboard
        hostingView.layoutSubtreeIfNeeded()
        expandGeneration += 1
        let generation = expandGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expandGeneration == generation else { return }
            withAnimation(Theme.expandSpring) {
                self.uiState.isExpanded = true
            }
        }
        // Ключевым панель становится только по явному клику (NotchPanel.sendEvent):
        // наведение не крадёт фокус ввода у активного приложения.
        // SwiftUI может домонтировать AppKit-вью (NSTextView и т.п.) лениво при
        // первом реальном показе — повторяем снятие регистрации на всякий случай.
        hostingView.unregisterDraggedTypesRecursively()
        refreshLimits()
    }

    private func handleEscape() {
        if uiState.selectedTab == .clipboard, !uiState.clipboardQuery.isEmpty {
            uiState.clipboardQuery = ""
        } else {
            collapse()
        }
    }

    /// Окно растёт вниз и симметрично в стороны от выреза; SwiftUI-остров — без анимации,
    /// иначе он отставал бы от окна при перетаскивании.
    private func resizePanel(to proposed: CGSize) {
        let size = NotchGeometry.clampedContentSize(proposed, screen: NotchGeometry.panelScreenFrame)
        guard size != NotchGeometry.contentSize else { return }
        NotchGeometry.contentSize = size
        let frame = NotchGeometry.expandedFrame()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            uiState.expandedSize = frame.size
        }
        panel.setFrame(frame, display: true)
    }

    private func finishResize() {
        uiState.isResizing = false
        NotchGeometry.storeContentSize(NotchGeometry.contentSize, in: .standard)
    }

    private func handleMouseExited() {
        expandWorkItem?.cancel()
        expandWorkItem = nil
        scheduleCollapseCheck(after: Self.collapseDelay)
    }

    private func scheduleCollapseCheck(after delay: TimeInterval) {
        collapseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.attemptCollapse()
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Не сворачиваем, пока фокус ввода — в текстовом поле (переводчик/таймер) И
    /// панель при этом ключевая, иначе панель схлопывается прямо во время печати.
    /// Field editor у TextField и текстовый движок под TextEditor — оба NSTextView.
    /// `isKeyWindow` обязателен: клик в другое приложение оставляет field editor
    /// "застрявшим" firstResponder навсегда — без этого условия проверка
    /// перепланировалась бы бесконечно и панель никогда не сворачивалась.
    private func attemptCollapse() {
        // Уголок тянут за пределы окна — панель не сворачиваем, пока пользователь не отпустит.
        if uiState.isResizing {
            scheduleCollapseCheck(after: Self.focusRecheckDelay)
            return
        }
        guard panel.isKeyWindow, panel.firstResponder is NSTextView else {
            collapse()
            return
        }
        scheduleCollapseCheck(after: Self.focusRecheckDelay)
    }

    private func collapse() {
        // Сбрасывает застрявший фокус (field editor), чтобы следующий цикл
        // проверки фокуса начинался чисто.
        panel.makeFirstResponder(nil)
        expandGeneration += 1
        uiState.isDropTargeted = false
        withAnimation(Theme.collapseAnimation) {
            uiState.isExpanded = false
        }
        let generation = expandGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseAnimationDuration) { [weak self] in
            guard let self, self.uiState.isExpanded == false, self.expandGeneration == generation else { return }
            self.panel.setFrame(NotchGeometry.collapsedFrame(), display: true)
        }
    }

    @objc private func windowDidResignKey() {
        guard uiState.isExpanded, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        scheduleCollapseCheck(after: 0)
    }

    private func updateGeometry() {
        uiState.topInset = NotchGeometry.notchHeight()
        uiState.notchWidth = NotchGeometry.notchWidth()
        uiState.collapsedSize = NotchGeometry.collapsedFrame().size
        uiState.expandedSize = NotchGeometry.expandedFrame().size
    }

    @objc private func screenParametersChanged() {
        updateGeometry()
        let frame = uiState.isExpanded ? NotchGeometry.expandedFrame() : NotchGeometry.collapsedFrame()
        panel.setFrame(frame, display: true)
    }
}

extension PanelController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        resizeMenuViews()
        // «N мин назад» пересчитывается при каждом открытии подменю статуса.
        if menu === statusSubmenu { fillStatusSubmenu() }
        // Подменю только подгоняют высоту — данные обновляет открытие главного меню.
        guard menu === statusItem?.menu else { return }
        // Открытие меню — всегда свежий запрос; параллельные запросы сторы сами не пускают.
        refreshEverything(force: false)
    }
}
