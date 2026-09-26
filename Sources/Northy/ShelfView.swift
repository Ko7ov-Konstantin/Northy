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
                        ShelfTile(url: url) {
                            withAnimation(Theme.tabSpring) { store.remove(url) }
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
/// панель действий: просмотр, «Поделиться», путь в буфер, Finder, убрать.
private struct ShelfTile: View {
    let url: URL
    let onRemove: () -> Void

    @State private var isHovering = false
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
                .scaleEffect(isHovering ? 1.08 : 1)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? Theme.cardHover : Theme.card)
        )
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                if fileExists {
                    IconButton(systemName: "eye", size: 20, help: "Быстрый просмотр") {
                        QuickLook.shared.show(url)
                    }
                    ShareButton(url: url)
                    IconButton(systemName: "doc.on.doc", size: 20, help: "Скопировать путь") {
                        FileActions.copyPath(url)
                    }
                    IconButton(systemName: "folder", size: 20, help: "Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", size: 20, help: "Убрать с полки", action: onRemove)
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
        .onHover { isHovering = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
    }
}
