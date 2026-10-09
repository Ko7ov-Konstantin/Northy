import AppKit
import SwiftUI

struct ShelfView: View {
    var store: ShelfStore

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 8)]

    var body: some View {
        if store.files.isEmpty {
            ShelfDropZone()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(store.files, id: \.path) { url in
                        ShelfTile(url: url, siblings: store.files, owned: store.ownsFile(url)) {
                            withAnimation(Theme.tabSpring) { store.remove(url) }
                        } onTrash: {
                            withAnimation(Theme.tabSpring) {
                                if !store.moveToTrash(url) { NSSound.beep() }
                            }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(Theme.tabSpring, value: store.files)
            }
        }
    }
}

private struct ShelfDropZone: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.amber.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.amber.opacity(0.04)))
            .overlay {
                EmptyStateView(
                    icon: "tray.and.arrow.down",
                    tint: Theme.amber,
                    title: "Перетащите файлы сюда",
                    subtitle: "Полка подержит их, пока не понадобятся"
                )
            }
    }
}

/// Плитка файла: большая иконка и имя. Перетаскивается наружу; по наведению —
/// панель действий: просмотр, «Поделиться», путь в буфер, Finder, в Корзину, убрать.
private struct ShelfTile: View {
    let url: URL
    /// Все файлы полки — быстрый просмотр листает их стрелками.
    let siblings: [URL]
    /// Файл Northy: отдельного «убрать с полки» нет, удаление — сразу с диска.
    let owned: Bool
    let onRemove: () -> Void
    let onTrash: () -> Void

    private static let actionSize: CGFloat = 19

    @State private var isHovering = false
    @State private var confirmsTrash = false
    @State private var spot = PointerSpot()
    @Environment(\.hoverGlowEnabled) private var glowEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    private var lit: Bool { isHovering && glowEnabled }
    /// Иконка и проверка существования кэшируются один раз на показ плитки:
    /// NSWorkspace.icon и stat при каждом body (наведение перерисовывает) — дорого.
    @State private var fileIcon: NSImage?
    @State private var fileExists = true

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let fileIcon {
                        Image(nsImage: fileIcon).resizable()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 46, height: 46)
                .opacity(fileExists ? 1 : 0.4)
                // Иконка приподнимается и светится янтарным ореолом.
                .background {
                    if lit {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.amber.opacity(0.35))
                            .blur(radius: 9)
                    }
                }
                .scaleEffect(lit && !reduceMotion ? 1.08 : 1)
                // Файл могли удалить или переместить после добавления на полку —
                // вместо молчаливой битой ссылки показываем признак и тусклим плитку.
                if !fileExists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.amber)
                        .help("Файл не найден на диске")
                }
            }
            Text(url.lastPathComponent)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(fileExists ? Theme.primaryText : Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: 28, alignment: .top)
        }
        .padding(.top, 12)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        // Свет плитки — поверх заливки и внутри формы: в сетке прокрутки ничего не выходит наружу.
        .background {
            if lit && !reduceMotion {
                PointerSheen(spot: spot, shape: Self.shape, tint: Theme.amber)
            }
        }
        .hoverGlow(lit, in: Self.shape, style: .plate(Theme.amber))
        .background(Self.shape.fill(isHovering ? Theme.cardHover : Theme.card))
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                if confirmsTrash {
                    Text("В Корзину?")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.leading, 6)
                    Spacer(minLength: 0)
                    IconButton(systemName: "checkmark", hoverTint: .red, size: Self.actionSize, help: "Удалить файл с диска", action: onTrash)
                    IconButton(systemName: "xmark", size: Self.actionSize, help: "Не удалять") { confirmsTrash = false }
                } else {
                    if fileExists {
                        IconButton(systemName: "eye", size: Self.actionSize, help: "Быстрый просмотр") {
                            QuickLook.shared.show(url, among: siblings)
                        }
                        ShareButton(url: url, size: Self.actionSize)
                        IconButton(systemName: "doc.on.doc", size: Self.actionSize, help: "Скопировать путь") {
                            FileActions.copyPath(url)
                        }
                        IconButton(systemName: "folder", size: Self.actionSize, help: "Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        IconButton(systemName: "trash", hoverTint: .red, size: Self.actionSize, help: "Удалить файл с диска — в Корзину") {
                            confirmsTrash = true
                        }
                    }
                    Spacer(minLength: 0)
                    if !owned || !fileExists {
                        IconButton(systemName: "xmark", size: Self.actionSize, help: "Убрать с полки", action: onRemove)
                    }
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .padding(1)
            )
            .opacity(isHovering ? 1 : 0)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering)
        .task(id: url.path) {
            fileExists = FileManager.default.fileExists(atPath: url.path)
            fileIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
        .onHover {
            isHovering = $0 && glowEnabled
            if !$0 { confirmsTrash = false }
        }
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
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
    }
}
