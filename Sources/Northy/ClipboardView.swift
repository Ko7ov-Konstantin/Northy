import AppKit
import SwiftUI

struct ClipboardView: View {
    var store: ClipboardStore
    @Bindable var uiState: PanelUIState

    @State private var kind: ClipboardStore.KindFilter = .all
    @State private var selectedID: UUID?
    @State private var copiedEntryID: UUID?
    /// Короткий отклик на строке: «Текст скопирован», ошибка распознавания.
    @State private var notice: (id: UUID, text: String, tint: Color)?
    @State private var recognizingID: UUID?
    @FocusState private var searchFocused: Bool

    /// Закреплённые — сверху, дальше история (новые выше).
    private var visible: [ClipboardStore.Entry] {
        let found = ClipboardStore.filtered(store.history, query: uiState.clipboardQuery, kind: kind)
        return found.filter(\.isPinned) + found.filter { !$0.isPinned }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !store.history.isEmpty {
                searchBar
            }
            if store.history.isEmpty {
                EmptyStateView(
                    icon: "doc.on.clipboard",
                    tint: Theme.sky,
                    title: "История пуста",
                    subtitle: "Всё, что вы скопируете, появится здесь"
                )
            } else if visible.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    tint: Theme.sky,
                    title: "Ничего не найдено",
                    subtitle: "Попробуйте другой запрос или фильтр"
                )
            } else {
                list
            }
        }
        .onChange(of: uiState.searchFocusRequest) { searchFocused = true }
        .onChange(of: uiState.clipboardQuery) { selectedID = nil }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                TextField("Поиск в истории  ⌘F", text: $uiState.clipboardQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primaryText)
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                    .onSubmit(copySelected)
                if !uiState.clipboardQuery.isEmpty {
                    // Как нативная кнопка отмены в поле поиска: только цвет и масштаб.
                    Button { uiState.clipboardQuery = "" } label: {
                        HoverReader { hovering in
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(hovering ? Theme.secondaryText : Theme.tertiaryText)
                                .contentShape(Circle())
                                .hoverGlow(hovering, in: Circle(), style: .glyph)
                                .animation(Hover.fade, value: hovering)
                        }
                    }
                    .buttonStyle(.pressable(scale: 0.9))
                    .handCursor()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(searchFocused ? Theme.sky.opacity(0.5) : .clear, lineWidth: 1))

            ChipPicker(options: ClipboardStore.KindFilter.allCases, selection: $kind, tint: Theme.sky, title: \.rawValue)
        }
    }

    private static let listTopID = "clipboard.listTop"

    private var list: some View {
        // Раз в полминуты обновляет «5 мин назад» во всех строках разом.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    let entries = visible
                    let pinned = entries.filter(\.isPinned)
                    let others = entries.filter { !$0.isPinned }
                    LazyVStack(spacing: 4) {
                        if !pinned.isEmpty {
                            SectionHeader(
                                icon: "pin.fill",
                                title: "Закреплённые",
                                tint: Theme.amber,
                                detail: "\(store.history.filter(\.isPinned).count) из \(store.pinLimit)"
                            )
                            // Закреплённые — в общей тёплой подложке, отдельно от потока истории.
                            VStack(spacing: 4) {
                                ForEach(pinned) { row($0, now: context.date) }
                            }
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(LinearGradient(colors: [Theme.amber.opacity(0.10), Theme.amber.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(LinearGradient(colors: [Theme.amber.opacity(0.4), Theme.amber.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                            )
                            if !others.isEmpty {
                                SectionHeader(icon: "clock", title: "История", tint: Theme.secondaryText, detail: "\(others.count)")
                                    .padding(.top, 6)
                            }
                        }
                        ForEach(others) { row($0, now: context.date) }
                    }
                    .animation(Theme.tabSpring, value: visible.map(\.id))
                    .id(Self.listTopID)
                }
                // Новое в буфере появляется сверху — при возврате на вкладку список открывается с начала.
                .onChange(of: uiState.selectedTab) { _, tab in
                    if tab == .clipboard { proxy.scrollTo(Self.listTopID, anchor: .top) }
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func row(_ entry: ClipboardStore.Entry, now: Date) -> some View {
        ClipboardRow(
            entry: entry,
            imageURL: imageURL(for: entry),
            now: now,
            isCopied: copiedEntryID == entry.id,
            isSelected: selectedID == entry.id,
            notice: notice?.id == entry.id ? notice.map { ($0.text, $0.tint) } : nil,
            isRecognizing: recognizingID == entry.id,
            onTap: { copy(entry) },
            onTogglePin: { togglePin(entry) },
            onRecognize: { recognize(entry) },
            onPreview: { preview(entry) },
            onRemove: { withAnimation(Theme.tabSpring) { store.remove(entry) } }
        )
        .id(entry.id)
        .transition(.asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity.combined(with: .scale(scale: 0.95))
        ))
    }

    /// Быстрый просмотр по всем картинкам видимого списка, начиная с этой.
    private func preview(_ entry: ClipboardStore.Entry) {
        guard let url = imageURL(for: entry) else { return }
        QuickLook.shared.show(url, among: visible.compactMap(imageURL(for:)))
    }

    private func togglePin(_ entry: ClipboardStore.Entry) {
        let done = withAnimation(Theme.tabSpring) { store.togglePin(entry) }
        guard !done else { return }
        show("Закреплено максимум — \(store.pinLimit), меняется в настройках", tint: Theme.amber, on: entry)
    }

    private func show(_ text: String, tint: Color, on entry: ClipboardStore.Entry) {
        withAnimation(Theme.tabSpring) { notice = (entry.id, text, tint) }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice?.id == entry.id, notice?.text == text {
                withAnimation(Theme.tabSpring) { notice = nil }
            }
        }
    }

    private func imageURL(for entry: ClipboardStore.Entry) -> URL? {
        guard case .image(let ref) = entry.content else { return nil }
        return store.imageURL(for: ref)
    }

    /// ↑↓ в поле поиска — выбор строки; Enter копирует выбранную (или первую).
    private func moveSelection(_ step: Int) {
        let ids = visible.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selectedID, let index = ids.firstIndex(of: current) else {
            selectedID = step > 0 ? ids.first : ids.last
            return
        }
        selectedID = ids[max(0, min(ids.count - 1, index + step))]
    }

    private func copySelected() {
        guard let entry = visible.first(where: { $0.id == selectedID }) ?? visible.first else { return }
        copy(entry)
    }

    private func copy(_ entry: ClipboardStore.Entry) {
        store.copyBack(entry)
        withAnimation(Theme.tabSpring) { copiedEntryID = entry.id }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedEntryID == entry.id {
                withAnimation(Theme.tabSpring) { copiedEntryID = nil }
            }
        }
    }

    /// Текст с картинки — в буфер (и, значит, отдельной записью в историю).
    private func recognize(_ entry: ClipboardStore.Entry) {
        guard let url = imageURL(for: entry), recognizingID == nil else { return }
        recognizingID = entry.id
        withAnimation(Theme.tabSpring) { notice = (entry.id, "Распознаю текст…", Theme.sky) }
        // Долго — значит, macOS грузит модель (после простоя или перезагрузки): говорим об этом.
        Task {
            try? await Task.sleep(for: .seconds(3))
            if recognizingID == entry.id {
                withAnimation(Theme.tabSpring) {
                    notice = (entry.id, "macOS загружает модель распознавания — первый раз до 30 с", Theme.sky)
                }
            }
        }
        Task {
            let message: String
            do {
                let text = try await TextRecognition.recognizeText(at: url)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                message = "Текст скопирован"
            } catch {
                message = error.localizedDescription
            }
            recognizingID = nil
            show(message, tint: Theme.mint, on: entry)
        }
    }
}

/// Заглушка пустой вкладки: иконка в светящемся круге и подпись.
struct EmptyStateView: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardStore.Entry
    let imageURL: URL?
    let now: Date
    let isCopied: Bool
    let isSelected: Bool
    let notice: (text: String, tint: Color)?
    let isRecognizing: Bool
    let onTap: () -> Void
    let onTogglePin: () -> Void
    let onRecognize: () -> Void
    let onPreview: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var spot = PointerSpot()
    @State private var thumbnail: NSImage?
    @Environment(\.hoverGlowEnabled) private var glowEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        HStack(spacing: 10) {
            leadingTile
                .overlay(alignment: .topLeading) {
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.amber)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.8)))
                            .offset(x: -5, y: -5)
                    }
                }
                .hoverGlow(isHovering, in: RoundedRectangle(cornerRadius: 8, style: .continuous), style: .tile(tileTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(notice?.text ?? meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(notice?.tint ?? Theme.tertiaryText)
                    .lineLimit(1)
            }
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        // Строка в ScrollView только светится изнутри: подъём обрезал бы края, ореол лез бы на соседей.
        // Свет — поверх заливки карточки, поэтому модификаторы идут до .background.
        .background {
            if showsSheen {
                PointerSheen(spot: spot, shape: Self.shape, tint: tileTint)
            }
        }
        .hoverGlow(isHovering && !isSelected && !isCopied, in: Self.shape, style: .surface(tileTint))
        .background {
            Self.shape
                .fill(isCopied ? Theme.mint.opacity(0.12) : (isHovering || isSelected ? Theme.cardHover : Theme.card))
        }
        .overlay(
            Self.shape
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.2 : 0.8)
        )
        // Без contentShape в HStack со Spacer кликается только область текста.
        .contentShape(Self.shape)
        .onHover { isHovering = $0 && glowEnabled }
        // Только координаты пятна: показ кнопок строки держится на onHover.
        .onContinuousHover { phase in
            guard glowEnabled, case .active(let point) = phase else {
                spot.location = nil
                return
            }
            spot.location = point
        }
        .onChange(of: glowEnabled) { _, on in
            if !on {
                isHovering = false
                spot.location = nil
            }
        }
        .onTapGesture(perform: onTap)
        .handCursor()
        .animation(isHovering ? Hover.enter : Hover.exit, value: isHovering)
        .help("Нажмите, чтобы скопировать")
    }

    private var borderColor: Color {
        if isCopied { return Theme.mint.opacity(0.45) }
        if isSelected { return Theme.sky.opacity(0.6) }
        return .clear
    }

    private var showsSheen: Bool {
        isHovering && glowEnabled && !isSelected && !isCopied && !reduceMotion
    }

    private var tileTint: Color {
        switch entry.content {
        case .text: Theme.sky
        case .files: Theme.amber
        case .image: Theme.violet
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isCopied {
            Label("Скопировано", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.mint)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            // Кнопки — обычные дочерние Button: SwiftUI отдаёт тап им, а не
            // onTapGesture строки, пока клик приходится на их собственную область.
            HStack(spacing: 2) {
                if case .image = entry.content {
                    IconButton(systemName: "eye", size: 22, help: "Быстрый просмотр — стрелками по всем картинкам", action: onPreview)
                    if isRecognizing {
                        ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                    } else {
                        IconButton(systemName: "text.viewfinder", size: 22, help: "Распознать текст и скопировать", action: onRecognize)
                    }
                }
                IconButton(
                    systemName: entry.isPinned ? "pin.slash" : "pin",
                    size: 22,
                    help: entry.isPinned ? "Открепить" : "Закрепить — запись не удалится",
                    action: onTogglePin
                )
                IconButton(systemName: "xmark", size: 22, help: "Убрать из истории", action: onRemove)
            }
            .opacity(isHovering || isRecognizing ? 1 : 0)
            // Кнопки выезжают справа, а не просто проявляются.
            .offset(x: isHovering || isRecognizing || reduceMotion ? 0 : 8)
        }
    }

    @ViewBuilder
    private var leadingTile: some View {
        switch entry.content {
        case .text:
            TypeTile(icon: "text.alignleft", tint: Theme.sky)
        case .files:
            TypeTile(icon: "doc.fill", tint: Theme.amber)
        case .image:
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.06)
                        .overlay(Image(systemName: "photo").foregroundStyle(Theme.secondaryText))
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            .task(id: imageURL) { await loadThumbnail() }
        }
    }

    /// Миниатюра декодируется в фоне из файла-оригинала и кэшируется.
    private func loadThumbnail() async {
        guard let imageURL else { return }
        if let cached = ThumbnailCache.shared.object(forKey: imageURL as NSURL) {
            thumbnail = cached
            return
        }
        let cgImage = await Task.detached(priority: .utility) {
            ClipboardImages.thumbnail(at: imageURL, maxPixel: 96)
        }.value
        guard let cgImage else { return }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        ThumbnailCache.shared.setObject(image, forKey: imageURL as NSURL)
        thumbnail = image
    }

    private var title: String {
        switch entry.content {
        case .text(let value):
            ClipboardStore.preview(of: value)
        case .files(let urls):
            urls.map(\.lastPathComponent).joined(separator: ", ")
        case .image:
            "Изображение"
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let date = entry.date {
            parts.append(Formatting.relative(date, now: now))
        }
        switch entry.content {
        case .text(let value):
            parts.append(Formatting.plural(value.utf16.count, ("символ", "символа", "символов")))
        case .files(let urls):
            parts.append(Formatting.plural(urls.count, ("файл", "файла", "файлов")))
        case .image(let ref):
            if ref.pixelWidth > 0 {
                parts.append("\(ref.pixelWidth)×\(ref.pixelHeight)")
            }
        }
        return parts.joined(separator: " · ")
    }
}

private struct TypeTile: View {
    let icon: String
    let tint: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.14)))
    }
}

@MainActor
enum ThumbnailCache {
    static let shared: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 150
        return cache
    }()
}

/// Шапка раздела списка: значок, название, тонкая светящаяся линия и счётчик.
private struct SectionHeader: View {
    let icon: String
    let title: String
    let tint: Color
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Capsule()
                .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            Text(detail)
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}
