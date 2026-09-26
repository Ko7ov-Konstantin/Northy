import AppKit
import SwiftUI

struct ClipboardView: View {
    var store: ClipboardStore
    @Bindable var uiState: PanelUIState

    @State private var kind: ClipboardStore.KindFilter = .all
    @State private var selectedID: UUID?
    @State private var copiedEntryID: UUID?
    /// Короткий отклик на строке: «Текст скопирован», ошибка распознавания.
    @State private var notice: (id: UUID, text: String)?
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
                    .pointerStyle(.link)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(searchFocused ? Theme.sky.opacity(0.5) : .clear, lineWidth: 1))

            ChipPicker(options: ClipboardStore.KindFilter.allCases, selection: $kind, tint: Theme.sky, title: \.rawValue)
        }
    }

    private var list: some View {
        // Раз в полминуты обновляет «5 мин назад» во всех строках разом.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visible) { entry in
                            ClipboardRow(
                                entry: entry,
                                imageURL: imageURL(for: entry),
                                now: context.date,
                                isCopied: copiedEntryID == entry.id,
                                isSelected: selectedID == entry.id,
                                notice: notice?.id == entry.id ? notice?.text : nil,
                                isRecognizing: recognizingID == entry.id,
                                onTap: { copy(entry) },
                                onTogglePin: { withAnimation(Theme.tabSpring) { store.togglePin(entry) } },
                                onRecognize: { recognize(entry) },
                                onRemove: { withAnimation(Theme.tabSpring) { store.remove(entry) } }
                            )
                            .id(entry.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.95))
                            ))
                        }
                    }
                    .animation(Theme.tabSpring, value: visible.map(\.id))
                }
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
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
            withAnimation(Theme.tabSpring) { notice = (entry.id, message) }
            try? await Task.sleep(for: .seconds(2))
            if notice?.id == entry.id {
                withAnimation(Theme.tabSpring) { notice = nil }
            }
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
    let notice: String?
    let isRecognizing: Bool
    let onTap: () -> Void
    let onTogglePin: () -> Void
    let onRecognize: () -> Void
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
                Text(notice ?? meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(notice == nil ? Theme.tertiaryText : Theme.mint)
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
        .pointerStyle(.link)
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
