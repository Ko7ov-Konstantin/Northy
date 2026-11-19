import Foundation
import Testing
@testable import Northy

@MainActor
/// Настраиваемые блоки вкладки «Лимиты»: состав, порядок, сохранение и выбор источника.
struct LimitsBlocksTests {

    private func isolatedSettings() throws -> (AppSettings, UserDefaults, String) {
        let suite = "NorthyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    @Test func allBlocksAreVisibleByDefault() throws {
        let (settings, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(settings.limitsBlocks == LimitsBlock.allCases)
        #expect(settings.menuProvider == .claude)
    }

    @Test func codexIsOfferedOnceWithoutChangingExistingChoices() throws {
        let (_, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: "limits.codexOffered")
        defaults.set(["glm"], forKey: "limits.providers")
        defaults.set(["glmLimits", "claudeCost"], forKey: "limits.blocks")

        let upgraded = AppSettings(defaults: defaults)
        #expect(Set(upgraded.enabledProviders.map(\.rawValue)) == ["glm", "codex"])
        #expect(upgraded.limitsBlocks.map(\.rawValue) == ["glmLimits", "codexLimits", "claudeCost", "codexPlanHistory"])

        upgraded.enabledProviders = [.glm]
        upgraded.limitsBlocks = [.glmLimits, .claudeCost]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.enabledProviders == [.glm])
        #expect(reloaded.limitsBlocks == [.glmLimits, .claudeCost])
    }

    @Test func blocksAndMenuTabPersist() throws {
        let (settings, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.limitsBlocks = [.glmLimits, .claudeCost]
        settings.menuProvider = .glm
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.limitsBlocks == [.glmLimits, .claudeCost])
        #expect(reloaded.menuProvider == .glm)

        settings.limitsBlocks = []
        #expect(AppSettings(defaults: defaults).limitsBlocks.isEmpty, "пустой список — тоже выбор, а не «по умолчанию»")
    }

    @Test func unknownAndRepeatedBlocksAreDropped() {
        #expect(LimitsBlock.sanitized(["glmDaily", "мусор", "claudeCost", "glmDaily"]) == [.glmDaily, .claudeCost])
    }

    @Test func smallChartsShareRow() {
        let rows = LimitsBlock.rows([.claudeLimits, .claudeDailyCost, .claudePlanHistory, .glmHourly, .glmDetails, .glmDaily])
        #expect(rows == [[.claudeLimits], [.claudeDailyCost, .claudePlanHistory], [.glmHourly], [.glmDetails], [.glmDaily]])
    }

    @Test func placingAddsOrMoves() {
        let blocks: [LimitsBlock] = [.claudeLimits, .glmLimits, .claudeCost]
        #expect(LimitsBlock.placing(.glmDetails, at: 1, in: blocks) == [.claudeLimits, .glmDetails, .glmLimits, .claudeCost])
        #expect(LimitsBlock.placing(.glmDetails, at: 99, in: blocks) == blocks + [.glmDetails])
        #expect(LimitsBlock.placing(.claudeLimits, at: 3, in: blocks) == [.glmLimits, .claudeCost, .claudeLimits], "перенос вниз")
        #expect(LimitsBlock.placing(.claudeCost, at: 0, in: blocks) == [.claudeCost, .claudeLimits, .glmLimits], "перенос вверх")
        #expect(LimitsBlock.placing(.glmLimits, at: 1, in: blocks) == blocks, "на своё место")
    }

    @Test func dropPointGivesInsertionIndex() {
        // Широкий блок, под ним два небольших в одной строке.
        let frames = [
            CGRect(x: 0, y: 0, width: 600, height: 100),
            CGRect(x: 0, y: 110, width: 295, height: 100),
            CGRect(x: 305, y: 110, width: 295, height: 100),
        ]
        #expect(LimitsBlock.insertionIndex(frames: frames, point: CGPoint(x: 100, y: -5)) == 0)
        #expect(LimitsBlock.insertionIndex(frames: frames, point: CGPoint(x: 500, y: 50)) == 1, "правая половина широкого — после него")
        #expect(LimitsBlock.insertionIndex(frames: frames, point: CGPoint(x: 100, y: 50)) == 0)
        #expect(LimitsBlock.insertionIndex(frames: frames, point: CGPoint(x: 200, y: 150)) == 2, "между двумя небольшими")
        #expect(LimitsBlock.insertionIndex(frames: frames, point: CGPoint(x: 500, y: 150)) == 3)
        #expect(LimitsBlock.insertionIndex(frames: frames, point: CGPoint(x: 10, y: 400)) == 3)
        #expect(LimitsBlock.insertionIndex(frames: [], point: .zero) == 0)
    }

    /// Источник показывается, когда включён в настройках и доступен на этом Mac.
    @Test func providersFollowSettingsKeyAndLogin() {
        let all = Set(LimitsProvider.allCases)
        #expect(LimitsProvider.available(enabled: all, hasGLMKey: true, hasGeminiLogin: true, hasCodexCLI: true) == [.claude, .glm, .gemini, .codex])
        #expect(LimitsProvider.available(enabled: all, hasGLMKey: true, hasGeminiLogin: true, hasCodexCLI: false) == [.claude, .glm, .gemini])
        #expect(LimitsProvider.available(enabled: all, hasGLMKey: false, hasGeminiLogin: true, hasCodexCLI: false) == [.claude, .gemini])
        #expect(LimitsProvider.available(enabled: all, hasGLMKey: true, hasGeminiLogin: false, hasCodexCLI: false) == [.claude, .glm])
        #expect(LimitsProvider.available(enabled: [.gemini], hasGLMKey: true, hasGeminiLogin: true, hasCodexCLI: true) == [.gemini])
        #expect(LimitsProvider.available(enabled: [.codex], hasGLMKey: false, hasGeminiLogin: false, hasCodexCLI: true) == [.codex])
        #expect(LimitsProvider.available(enabled: [.glm, .gemini], hasGLMKey: false, hasGeminiLogin: false, hasCodexCLI: false).isEmpty)
        #expect(LimitsProvider.available(enabled: [], hasGLMKey: true, hasGeminiLogin: true, hasCodexCLI: true).isEmpty)

        #expect(LimitsProvider.resolve(.glm, available: [.claude, .glm]) == .glm)
        #expect(LimitsProvider.resolve(.glm, available: [.claude]) == .claude)
        #expect(LimitsProvider.resolve(.gemini, available: [.claude, .gemini]) == .gemini)
        #expect(LimitsProvider.resolve(.claude, available: []) == nil)
        #expect(LimitsBlock.geminiLimits.provider == .gemini)
        #expect(LimitsBlock.geminiPlanHistory.provider == .gemini)
        #expect(LimitsBlock.glmPlanHistory.provider == .glm)
    }

    /// Убранный из вкладки блок не выключает источник: это разные настройки.
    @Test func removingBlockKeepsProviderEnabled() throws {
        let (settings, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(settings.enabledProviders == Set(LimitsProvider.allCases))
        settings.limitsBlocks.removeAll { $0 == .geminiLimits || $0 == .claudeLimits }
        #expect(settings.enabledProviders == Set(LimitsProvider.allCases))

        settings.enabledProviders = [.gemini]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.enabledProviders == [.gemini])
        #expect(reloaded.limitsBlocks == settings.limitsBlocks, "выключенный источник блоки не трогает")
    }

    /// Раньше источник выключали, убирая его блок лимитов: этот выбор сохраняется, Gemini включён.
    @Test func enabledProvidersComeFromOldBlocksOnce() throws {
        let (_, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: "limits.providers")
        defaults.set(["glmLimits", "claudeCost"], forKey: "limits.blocks")
        #expect(AppSettings(defaults: defaults).enabledProviders == [.glm, .gemini])

        defaults.set(["claudeLimits"], forKey: "limits.blocks")
        #expect(AppSettings(defaults: defaults).enabledProviders == [.glm, .gemini], "второй раз из блоков не выводится")
    }

    /// Пункты меню «Дашборд» и «Страница статуса» есть только у источника, у которого есть адрес.
    @Test func menuLinksPerProvider() {
        #expect(LimitsProvider.claude.dashboardURL?.absoluteString == "https://claude.ai/settings/usage")
        #expect(LimitsProvider.glm.dashboardURL == ZaiWeb.dashboardURL)
        #expect(LimitsProvider.gemini.dashboardURL == nil)
        #expect(LimitsProvider.claude.statusPageURL?.absoluteString == "https://status.claude.com")
        #expect(LimitsProvider.glm.statusPageURL == nil, "у Z.AI нет публичной страницы статуса")
        #expect(LimitsProvider.gemini.statusPageURL?.absoluteString == "https://www.google.com/appsstatus/dashboard/products/npdyhgECDJ6tB66MxXyo/history")
    }

    @Test func limitBlocksStayAtTheTop() {
        #expect(LimitsBlock.limitsIndex(for: .claudeLimits, in: [.glmLimits, .claudeCost]) == 0)
        #expect(LimitsBlock.limitsIndex(for: .glmLimits, in: [.claudeLimits, .geminiLimits, .claudeCost]) == 1)
        #expect(LimitsBlock.limitsIndex(for: .geminiLimits, in: [.claudeLimits, .glmLimits, .claudeCost]) == 2)
        #expect(LimitsBlock.limitsIndex(for: .geminiLimits, in: [.claudeCost]) == 0)
        #expect(LimitsBlock.limitsIndex(for: .glmLimits, in: [.geminiLimits, .claudeCost]) == 0)
    }

    /// У каждого источника своя история замеров — графики «Использование плана» не смешиваются.
    @Test func historyFilePerProvider() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NorthyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_785_800_000)
        let snapshot = UsageSnapshot(windows: [
            UsageWindow(kind: .session, percent: 10, resetsAt: now + 3600),
            UsageWindow(kind: .weekly, percent: 20, resetsAt: now + 86_400),
        ], fetchedAt: now)

        let gemini = UsageHistory(directory: directory, fileName: LimitsProvider.gemini.historyFileName)
        gemini.record(snapshot)
        gemini.flush()
        #expect(UsageHistory(directory: directory, fileName: LimitsProvider.gemini.historyFileName).samples.count == 1)
        #expect(UsageHistory(directory: directory, fileName: LimitsProvider.glm.historyFileName).samples.isEmpty)
        #expect(UsageHistory(directory: directory).samples.isEmpty)
        #expect(LimitsProvider.claude.historyFileName == "claude-usage-history.json", "прежний файл истории Claude")
    }

    /// Блоки Gemini появились позже: в уже настроенный список они добавляются один раз.
    @Test func geminiBlocksAreOfferedOnceToSavedList() throws {
        let (_, defaults, suite) = try isolatedSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: "limits.geminiBlocksOffered")
        defaults.set(["claudeLimits", "glmLimits", "claudeCost"], forKey: "limits.blocks")

        let upgraded = AppSettings(defaults: defaults)
        #expect(upgraded.limitsBlocks == [.claudeLimits, .glmLimits, .geminiLimits, .claudeCost, .glmPlanHistory, .geminiDetails, .geminiPlanHistory])

        upgraded.limitsBlocks = [.claudeLimits]
        #expect(AppSettings(defaults: defaults).limitsBlocks == [.claudeLimits], "убранные блоки сами не возвращаются")
    }
}
