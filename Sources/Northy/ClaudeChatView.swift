import AppKit
import SwiftUI

/// Окно «Вопрос Claude»: переписка, выбор модели и поле ввода.
struct ClaudeChatView: View {
    @Bindable var store: ClaudeChatStore
    @State private var draft = ""
    @State private var confirmsDelete = false
    @FocusState private var inputFocused: Bool

    private static let bottom = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(Theme.edge).frame(height: 1)
            messageList
            inputBar
        }
        .background(Theme.islandBottom)
        .foregroundStyle(Theme.primaryText)
        .onAppear { inputFocused = true }
        .onChange(of: store.focusRequest) { inputFocused = true }
        .confirmationDialog("Удалить переписку и сессию Claude Code?", isPresented: $confirmsDelete) {
            Button("Удалить", role: .destructive) { store.deleteSession() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                pickerRow("Модель") {
                    ChipPicker(options: ChatModel.allCases, selection: $store.model, tint: Theme.sky, title: \.title)
                }
                Spacer(minLength: 8)
                Button("Удалить сессию") { confirmsDelete = true }
                    .buttonStyle(.pressable)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .handCursor()
                    .disabled(store.messages.isEmpty)
                    .opacity(store.messages.isEmpty ? 0.4 : 1)
                    .help("Стереть переписку и файл сессии Claude Code")
            }
            pickerRow("Рассуждение") {
                ChipPicker(options: ChatEffort.allCases, selection: $store.effort, tint: Theme.violet, title: \.rawValue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func pickerRow(_ title: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 80, alignment: .leading)
            picker()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    if store.messages.isEmpty {
                        Text("Спросите что угодно — Claude может искать в интернете")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.top, 40)
                    }
                    ForEach(store.messages) { message in
                        if !message.text.isEmpty { MessageBubble(message: message) }
                    }
                    if let progress {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(progress)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondaryText)
                            Spacer(minLength: 0)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(14)
            }
            .onChange(of: store.messages.last?.text) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: store.messages.count) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            .onChange(of: store.isSearching) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    /// Пока ответ пуст — «Думает…»; идущий текст сам показывает, что ответ жив.
    private var progress: String? {
        guard store.isAnswering else { return nil }
        if store.isSearching { return "Ищет в интернете…" }
        return store.messages.last?.text.isEmpty == true ? "Думает…" : nil
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($inputFocused)
                .frame(minHeight: 22, maxHeight: 110)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Вопрос…  Enter — отправить, Shift+Enter — новая строка")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .onKeyPress(keys: [.return]) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    submit()
                    return .handled
                }
            actionButton
        }
        .padding(14)
    }

    private var actionButton: some View {
        let isAnswering = store.isAnswering
        let tint = isAnswering ? Theme.danger : Theme.sky
        return Button(isAnswering ? "Остановить" : "Отправить") {
            if isAnswering { store.stop() } else { submit() }
        }
        .buttonStyle(.pressable)
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(tint.opacity(0.22)))
        .contentShape(Capsule())
        .hoverGlow(in: Capsule(), style: .capsule(tint))
        .handCursor()
    }

    private func submit() {
        guard !store.isAnswering, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.send(draft)
        draft = ""
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 48) }
            text
                .font(.system(size: 13))
                .foregroundStyle(message.role == .error ? Theme.danger : Theme.primaryText)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill))
            if message.role != .user { Spacer(minLength: 48) }
        }
    }

    /// Ответ — Markdown со строчной разметкой, без блочной: переносы и пробелы сохраняются, ссылки кликабельны.
    private var text: Text {
        guard message.role == .assistant else { return Text(verbatim: message.text) }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: message.text, options: options)) ?? AttributedString(message.text))
    }

    private var fill: Color {
        switch message.role {
        case .user: Theme.sky.opacity(0.22)
        case .assistant: Theme.card
        case .error: Theme.danger.opacity(0.12)
        }
    }
}

/// Обычное окно чата, как у настроек: accessory-приложению нужна явная активация, иначе окно окажется позади.
final class ChatWindowController {
    private var window: NSWindow?
    /// nil, пока чат не открывали: тогда ни истории, ни процесса нет.
    private(set) var store: ClaudeChatStore?
    private let makeStore: () -> ClaudeChatStore

    init(makeStore: @escaping () -> ClaudeChatStore) {
        self.makeStore = makeStore
    }

    func show() {
        let store = store ?? makeStore()
        self.store = store
        if window == nil {
            let hosting = NSHostingController(rootView: ClaudeChatView(store: store))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "Вопрос Claude"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            // Окно открывается на текущем рабочем столе, а не уводит на тот, где его оставили.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.setContentSize(NSSize(width: 520, height: 620))
            window.contentMinSize = NSSize(width: 400, height: 440)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        store.focusRequest += 1
    }
}
