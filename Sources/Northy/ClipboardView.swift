import AppKit
import SwiftUI

struct ClipboardView: View {
    var store: ClipboardStore

    @State private var copiedEntryID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("История буфера обмена")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Очистить") { store.clear() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if store.history.isEmpty {
                Spacer()
                Text("Пусто")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.history) { entry in
                            ClipboardRow(
                                entry: entry,
                                isCopied: copiedEntryID == entry.id,
                                onTap: { handleTap(entry) },
                                onRemove: { store.remove(entry) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func handleTap(_ entry: ClipboardStore.Entry) {
        store.copyBack(entry)
        copiedEntryID = entry.id
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }
}

/// Своя вью ради @State-hover: фон и заметность кнопки удаления появляются
/// только при наведении, а не висят постоянно.
private struct ClipboardRow: View {
    let entry: ClipboardStore.Entry
    let isCopied: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false
    /// Миниатюра декодируется один раз на показ строки, а не при каждом
    /// body-вычислении (hover менял состояние и заново декодировал весь Data).
    @State private var imageThumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(summaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            Spacer()
            if isCopied {
                Label("Скопировано", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            // Кнопка — обычный дочерний Button внутри строки: SwiftUI отдаёт тап ей,
            // а не onTapGesture строки, пока клик приходится на её собственную область.
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 0.8 : 0.35)
        }
        .padding(8)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Без contentShape в HStack со Spacer кликается только область текста.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.content {
        case .text:
            Image(systemName: "doc.on.clipboard")
                .frame(width: 24)
                .foregroundStyle(.secondary)
        case .files:
            Image(systemName: "folder")
                .frame(width: 24)
                .foregroundStyle(.secondary)
        case .image(let data):
            if let imageThumbnail {
                Image(nsImage: imageThumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "photo")
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                    .task(id: entry.id) { imageThumbnail = NSImage(data: data) }
            }
        }
    }

    private var summaryText: String {
        switch entry.content {
        case .text(let value):
            value.replacingOccurrences(of: "\n", with: " ")
        case .files(let urls):
            "Файлы: " + urls.map(\.lastPathComponent).joined(separator: ", ")
        case .image:
            "Изображение"
        }
    }
}
