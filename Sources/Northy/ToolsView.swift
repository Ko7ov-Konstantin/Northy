import AppKit
import SwiftUI

struct ToolsView: View {
    var store: ToolsStore

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 140), spacing: 8)]
    private let tint = PanelTab.tools.tint

    private var isIdle: Bool { store.activity == .idle }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if store.needsPermission {
                    PermissionHint()
                }
                // Новая плитка — ещё одна строка здесь.
                LazyVGrid(columns: columns, spacing: 8) {
                    captureTile(.area, icon: "rectangle.dashed", title: "Снимок области")
                    captureTile(.window, icon: "macwindow", title: "Снимок окна")
                    captureTile(.screen, icon: "display", title: "Снимок экрана")
                    captureTile(.text, icon: "text.viewfinder", title: "Текст с экрана")
                    recordingTile
                    pickRecordingTile(.window, icon: "macwindow.badge.plus", title: "Запись окна")
                    pickRecordingTile(.area, icon: "rectangle.dashed.badge.record", title: "Запись области")
                    ToolTile(icon: "eyedropper", title: "Пипетка", tint: tint, isActive: store.activity == .pickingColor, action: {
                        Task { await store.pickColor() }
                    })
                    .disabled(!isIdle)
                    ToolTile(icon: "cup.and.saucer.fill", title: "Не давать уснуть", tint: tint, isActive: store.isKeepingAwake, action: {
                        store.setKeepAwake(!store.isKeepingAwake)
                    })
                    ToolTile(icon: store.script.isRunning ? "stop.circle.fill" : "play.circle", title: "Скрипт", tint: tint, isActive: store.script.isRunning, action: {
                        Task { await store.script.toggle() }
                    })
                    .help(store.script.scriptName ?? "Скрипт")
                    .contextMenu {
                        Button("Выбрать другой скрипт…") { Task { await store.script.chooseScript() } }
                            .disabled(store.script.isRunning)
                    }
                    ToolTile(icon: "bubble.left.and.text.bubble.right", title: "Задать вопрос", tint: tint, isActive: false, action: { store.openChat() })
                }
                if let status = store.status ?? store.script.status {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
            }
            .animation(Theme.tabSpring, value: store.status ?? store.script.status)
            .animation(Theme.tabSpring, value: store.needsPermission)
        }
    }

    private func captureTile(_ mode: ScreenCapture.Mode, icon: String, title: String) -> some View {
        ToolTile(icon: icon, title: title, tint: tint, isActive: store.activity == .capturing(mode), action: {
            Task { await store.capture(mode) }
        })
        .disabled(!isIdle)
    }

    /// Запись, для которой сначала выбирают область или окно.
    private func pickRecordingTile(_ kind: ToolsStore.RecordingKind, icon: String, title: String) -> some View {
        ToolTile(icon: icon, title: title, tint: tint, isActive: false, action: {
            Task { await store.startRecording(kind) }
        })
        .disabled(!isIdle)
    }

    @ViewBuilder
    private var recordingTile: some View {
        switch store.activity {
        case .recording(let since):
            ToolTile(icon: "stop.circle.fill", title: "Остановить", tint: Theme.danger, isActive: true, action: store.stopRecording) {
                Text(since, style: .timer)
            }
        case .finishing:
            ToolTile(icon: "record.circle", title: "Сохраняю запись…", tint: Theme.danger, isActive: true, action: {})
                .disabled(true)
        default:
            ToolTile(icon: "record.circle", title: "Запись экрана", tint: tint, isActive: false, action: {
                Task { await store.startRecording() }
            })
            .disabled(!isIdle)
        }
    }
}

/// Плитка действия — тот же вид, что у плиток полки.
private struct ToolTile<Detail: View>: View {
    let icon: String
    let title: String
    let tint: Color
    /// Действие выполняется: плитка подсвечена своим цветом.
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder var detail: Detail

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    init(icon: String, title: String, tint: Color, isActive: Bool, action: @escaping () -> Void, @ViewBuilder detail: () -> Detail = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.tint = tint
        self.isActive = isActive
        self.action = action
        self.detail = detail()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(height: 34)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                detail
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 86)
            .background(Self.shape.fill(isActive ? tint.opacity(0.16) : Theme.card))
            .overlay {
                if isActive {
                    Self.shape.strokeBorder(tint.opacity(0.5), lineWidth: 1)
                }
            }
            .contentShape(Self.shape)
            .hoverGlow(in: Self.shape, style: .plate(tint))
        }
        .buttonStyle(.pressable)
        .handCursor()
        .help(title)
    }
}

/// Без разрешения «Запись экрана» действие не запускается — подсказка, как его выдать.
private struct PermissionHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 6) {
                Text("Нужно разрешение „Запись экрана“; после включения перезапустите Northy")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть настройки") { NSWorkspace.shared.open(ScreenCapture.settingsURL) }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.amber.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.amber.opacity(0.3), lineWidth: 1))
    }
}
