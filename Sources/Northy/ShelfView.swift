import AppKit
import SwiftUI

struct ShelfView: View {
    var store: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Полка файлов")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button("Очистить полку") { store.clear() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            if store.files.isEmpty {
                Spacer()
                Text("Перетащите файлы сюда")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(store.files, id: \.path) { url in
                            ShelfRow(url: url, onRemove: { store.remove(url) })
                        }
                    }
                }
            }
        }
    }
}

/// Своя вью ради @State-hover: фон и заметность кнопки удаления появляются
/// только при наведении, а не висят постоянно.
private struct ShelfRow: View {
    let url: URL
    let onRemove: () -> Void

    @State private var isHovering = false

    /// Файл могли удалить или переместить после добавления на полку — вместо
    /// молчаливой битой ссылки показываем признак и тусклим строку.
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 24, height: 24)
            Text(url.lastPathComponent)
                .foregroundStyle(fileExists ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !fileExists {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Файл не найден на диске")
            }
            Spacer()
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
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
    }
}
