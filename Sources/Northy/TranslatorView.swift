import AppKit
import NaturalLanguage
import SwiftUI
import Translation

struct TranslatorView: View {
    @State private var sourceText = ""
    @State private var resultText = ""
    @State private var sourceLanguage: SourceLanguage = .auto
    @State private var targetLanguage: TargetLanguage = .en
    @State private var configuration: TranslationSession.Configuration?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var debounceTask: Task<Void, Never>?
    @State private var isResultCopied = false
    @State private var swapRotation: Double = 0

    private static let debounceDelay: UInt64 = 500_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Переводчик")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                languageControls
            }

            TextEditor(text: $sourceText)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.primary)
                .frame(minHeight: 70)
                .onChange(of: sourceText) { _, newValue in
                    scheduleDebouncedTranslate(for: newValue)
                }

            ScrollView {
                Text(resultText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.primary)
            }
            .frame(minHeight: 70)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if !resultText.isEmpty {
                    Button(action: copyResult) {
                        Image(systemName: isResultCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(8)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .translationTask(configuration) { @Sendable session in
            let text = await sourceText
            do {
                try await session.prepareTranslation()
                let response = try await session.translate(text)
                await MainActor.run {
                    resultText = response.targetText
                    statusMessage = nil
                    errorMessage = nil
                }
            } catch TranslationError.nothingToTranslate {
                // «Авто» определил язык, совпавший с целью, — переводить нечего,
                // это не ошибка пользователя.
                await MainActor.run {
                    resultText = text
                    statusMessage = nil
                    errorMessage = nil
                }
            } catch {
                await MainActor.run { errorMessage = fallbackErrorMessage(error) }
            }
        }
    }

    /// Кастомные Menu в этой nonactivating-панели рендерились без видимого текста —
    /// заменены на кнопки, циклически переключающие значение по клику; значение
    /// всегда видно без наведения.
    private var languageControls: some View {
        HStack(spacing: 8) {
            languagePill(sourceLanguage.rawValue) { cycleSource() }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    swapRotation += 180
                }
                swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .rotationEffect(.degrees(swapRotation))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            languagePill(targetLanguage.rawValue) { cycleTarget() }
        }
    }

    private func languagePill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cycleSource() {
        switch sourceLanguage {
        case .auto: sourceLanguage = .ru
        case .ru: sourceLanguage = .en
        case .en: sourceLanguage = .auto
        }
        restartTranslateNow()
    }

    private func cycleTarget() {
        targetLanguage = targetLanguage == .ru ? .en : .ru
        restartTranslateNow()
    }

    /// Если источник «Авто» — источником становится текущая цель, целью — противоположный язык.
    /// Иначе — обычная перестановка местами.
    private func swapLanguages() {
        let newSource = targetLanguage.asSource
        let newTarget: TargetLanguage = sourceLanguage.locale == nil
            ? (targetLanguage == .ru ? .en : .ru)
            : (sourceLanguage == .ru ? .ru : .en)
        sourceLanguage = newSource
        targetLanguage = newTarget
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
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            isResultCopied = false
        }
    }

    private func scheduleDebouncedTranslate(for text: String) {
        debounceTask?.cancel()
        guard !text.isEmpty else {
            resultText = ""
            errorMessage = nil
            statusMessage = nil
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
        let pairDescription = "\(sourceLanguage.rawValue) → \(targetLanguage.rawValue)"

        guard source != target else {
            resultText = sourceText
            statusMessage = nil
            errorMessage = nil
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
            triggerTranslation(source: source, target: target)
        case .supported:
            statusMessage = """
            Скачиваются языковые пакеты (\(pairDescription))… \
            Если диалог не появился: Настройки → Основные → Язык и регион → Языки перевода
            """
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
