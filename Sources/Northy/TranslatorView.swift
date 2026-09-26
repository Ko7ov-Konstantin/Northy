import AppKit
import NaturalLanguage
import SwiftUI
import Translation

struct TranslatorView: View {
    @State private var sourceText = ""
    @State private var resultText = ""
    /// Языки переживают перезапуск — AppStorage держит их в UserDefaults.
    @AppStorage("translator.sourceLanguage") private var sourceLanguage: SourceLanguage = .auto
    @AppStorage("translator.targetLanguage") private var targetLanguage: TargetLanguage = .en
    @State private var configuration: TranslationSession.Configuration?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var isResultCopied = false
    /// «Вставлено» / «Буфер пуст» на кнопке вставки; nil — обычная подпись.
    @State private var pasteFeedback: String?
    @State private var swapRotation: Double = 0
    @State private var isTranslating = false
    /// Язык, определённый для «Авто» по последнему тексту («RU»/«EN»).
    @State private var detectedSource: String?

    private static let debounceDelay: UInt64 = 500_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            languageControls

            HStack(spacing: 10) {
                sourcePane
                resultPane
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .transition(.opacity)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: errorMessage)
        .animation(.easeOut(duration: 0.2), value: statusMessage)
        .translationTask(configuration) { @Sendable session in
            let text = await sourceText
            do {
                try await session.prepareTranslation()
                let response = try await session.translate(text)
                await MainActor.run {
                    resultText = response.targetText
                    statusMessage = nil
                    errorMessage = nil
                    isTranslating = false
                }
            } catch TranslationError.nothingToTranslate {
                // «Авто» определил язык, совпавший с целью, — переводить нечего,
                // это не ошибка пользователя.
                await MainActor.run {
                    resultText = text
                    statusMessage = nil
                    errorMessage = nil
                    isTranslating = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = fallbackErrorMessage(error)
                    isTranslating = false
                }
            }
        }
    }

    private var sourcePane: some View {
        TextEditor(text: $sourceText)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            // Место под кнопками «очистить» и «Вставить», чтобы они не закрывали текст.
            .padding(.bottom, 34)
            .background(alignment: .topLeading) {
                if sourceText.isEmpty {
                    Text("Введите или вставьте текст…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiaryText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .paneStyle(tint: Theme.violet, highlighted: false)
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    if !sourceText.isEmpty {
                        IconButton(systemName: "xmark", size: 22, help: "Очистить текст") {
                            sourceText = ""
                        }
                        .transition(.opacity)
                    }
                    Button(action: pasteSource) {
                        Label(pasteFeedback ?? "Вставить",
                              systemImage: pasteFeedback == nil ? "doc.on.clipboard" : "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(pasteFeedback == nil ? Theme.primaryText : Theme.mint)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .contentShape(Capsule())
                            .hoverGlow(in: Capsule(), style: .capsule(pasteFeedback == nil ? Theme.violet : Theme.mint))
                    }
                    .buttonStyle(.pressable)
                    .pointerStyle(.link)
                    .help("Заменить текст содержимым буфера обмена")
                    .animation(Theme.tabSpring, value: pasteFeedback)
                }
                .padding(6)
            }
            .onChange(of: sourceText) { _, newValue in
                scheduleDebouncedTranslate(for: newValue)
            }
    }

    private var resultPane: some View {
        ScrollView {
            Group {
                if resultText.isEmpty {
                    Text("Перевод появится здесь")
                        .foregroundStyle(Theme.tertiaryText)
                } else {
                    Text(resultText)
                        .foregroundStyle(Theme.primaryText)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
        .paneStyle(tint: Theme.violet, highlighted: !resultText.isEmpty)
        .overlay(alignment: .topTrailing) {
            if isTranslating {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.violet)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !resultText.isEmpty {
                Button(action: copyResult) {
                    Label(isResultCopied ? "Скопировано" : "Копировать",
                          systemImage: isResultCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isResultCopied ? Theme.mint : Theme.primaryText)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .contentShape(Capsule())
                        .hoverGlow(in: Capsule(), style: .capsule(isResultCopied ? Theme.mint : Theme.violet))
                }
                .buttonStyle(.pressable)
                .pointerStyle(.link)
                .padding(6)
                .animation(Theme.tabSpring, value: isResultCopied)
            }
        }
    }

    /// Кастомные Menu в этой nonactivating-панели рендерились без видимого текста —
    /// заменены на кнопки, циклически переключающие значение по клику; значение
    /// всегда видно без наведения.
    private var languageControls: some View {
        HStack(spacing: 8) {
            languagePill(sourceTitle) { cycleSource() }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    swapRotation += 180
                }
                swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.violet)
                    .rotationEffect(.degrees(swapRotation))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.violet.opacity(0.15)))
                    .contentShape(Circle())
                    .hoverGlow(in: Circle(), style: .accentCircle(Theme.violet))
            }
            .buttonStyle(.pressable)
            .pointerStyle(.link)
            .help("Поменять языки местами")

            languagePill(targetLanguage.rawValue) { cycleTarget() }

            Spacer()
        }
    }

    /// Для «Авто» рядом показывается язык, который определился по тексту.
    private var sourceTitle: String {
        guard sourceLanguage == .auto, let detectedSource else { return sourceLanguage.rawValue }
        return "Авто · \(detectedSource)"
    }

    private func languagePill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HoverReader { hovering in
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.opacity)
                    // Шеврон светлеет под курсором — подсказка, что клик переключает язык.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(hovering ? Theme.primaryText : Theme.secondaryText)
                        .animation(Hover.fade, value: hovering)
                }
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .contentShape(Capsule())
                .hoverGlow(hovering, in: Capsule(), style: .capsule(Theme.violet))
                .animation(.easeOut(duration: 0.15), value: title)
            }
        }
        .buttonStyle(.pressable)
        .pointerStyle(.link)
    }

    private func cycleSource() {
        sourceLanguage = sourceLanguage.next
        restartTranslateNow()
    }

    private func cycleTarget() {
        targetLanguage = targetLanguage.next
        restartTranslateNow()
    }

    private func swapLanguages() {
        let swapped = swapped(source: sourceLanguage, target: targetLanguage)
        sourceLanguage = swapped.source
        targetLanguage = swapped.target
        restartTranslateNow()
    }

    /// Смена языков применяется сразу, без дебаунса ввода.
    private func restartTranslateNow() {
        debounceTask?.cancel()
        if !sourceText.isEmpty { performTranslate() }
    }

    private func copyResult() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(resultText, forType: .string)
        isResultCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            isResultCopied = false
        }
    }

    /// Текст из буфера заменяет исходный; перевод запускается как при вводе.
    private func pasteSource() {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            pasteFeedback = "Буфер пуст"
        } else {
            sourceText = text
            pasteFeedback = "Вставлено"
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            pasteFeedback = nil
        }
    }

    private func scheduleDebouncedTranslate(for text: String) {
        debounceTask?.cancel()
        guard !text.isEmpty else {
            resultText = ""
            errorMessage = nil
            statusMessage = nil
            isTranslating = false
            detectedSource = nil
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            performTranslate()
        }
    }

    private func performTranslate() {
        guard !sourceText.isEmpty else { return }
        errorMessage = nil
        statusMessage = nil
        Task { await checkAvailabilityAndTranslate() }
    }

    /// «Авто» больше не отдаёт nil source в Configuration — судя по диагностике,
    /// системное auto-detect в этом accessory/borderless-окружении не срабатывает
    /// (пакеты установлены, LanguageAvailability = installed, а перевод всё равно
    /// падает). Поэтому язык определяем сами через NaturalLanguage, локально,
    /// без обращения к translationd, и в Configuration всегда уходит явная пара.
    private func resolvedSourceLocale(for text: String) -> Locale.Language {
        guard let explicit = sourceLanguage.locale else {
            return detectLanguage(in: text)
        }
        return explicit
    }

    private func detectLanguage(in text: String) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.russian, .english]
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .russian: return Locale.Language(identifier: "ru")
        case .english: return Locale.Language(identifier: "en")
        default: break
        }
        let hasCyrillic = text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
        return Locale.Language(identifier: hasCyrillic ? "ru" : "en")
    }

    /// LanguageAvailability.status(from:to:) теперь всегда проверяется по уже
    /// определённой явной паре — кандидатская логика для «Авто» больше не нужна.
    private func checkAvailabilityAndTranslate() async {
        let target = targetLanguage.locale
        let source = resolvedSourceLocale(for: sourceText)
        detectedSource = source.languageCode?.identifier.uppercased()
        let pairDescription = "\(sourceLanguage.rawValue) → \(targetLanguage.rawValue)"

        guard source != target else {
            resultText = sourceText
            statusMessage = nil
            errorMessage = nil
            isTranslating = false
            return
        }

        let status = await LanguageAvailability().status(from: source, to: target)
        applyStatus(status, pairDescription: pairDescription, source: source, target: target)
    }

    private func applyStatus(
        _ status: LanguageAvailability.Status,
        pairDescription: String,
        source: Locale.Language,
        target: Locale.Language
    ) {
        switch status {
        case .installed:
            isTranslating = true
            triggerTranslation(source: source, target: target)
        case .supported:
            statusMessage = """
            Скачиваются языковые пакеты (\(pairDescription))… \
            Если диалог не появился: Настройки → Основные → Язык и регион → Языки перевода
            """
            isTranslating = true
            triggerTranslation(source: source, target: target)
        case .unsupported:
            errorMessage = "Пара языков \(pairDescription) не поддерживается для офлайн-перевода."
        @unknown default:
            errorMessage = "Неизвестный статус пары языков \(pairDescription)."
        }
    }

    private func triggerTranslation(source: Locale.Language, target: Locale.Language) {
        if var current = configuration, current.source == source, current.target == target {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func fallbackErrorMessage(_ error: Error) -> String {
        let pairDescription = "\(sourceLanguage.rawValue) → \(targetLanguage.rawValue)"
        return """
        Ошибка перевода (\(pairDescription)): \(error.localizedDescription)
        Проверьте: Настройки → Основные → Язык и регион → Языки перевода
        """
    }
}

private extension View {
    /// Подложка текстовой панели переводчика; с результатом — лёгкий акцент.
    func paneStyle(tint: Color, highlighted: Bool) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlighted ? tint.opacity(0.08) : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlighted ? tint.opacity(0.25) : Color.white.opacity(0.06), lineWidth: 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
