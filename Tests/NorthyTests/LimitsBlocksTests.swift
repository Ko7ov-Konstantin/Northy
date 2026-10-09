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

    /// Скрытые лимиты Claude — источник пропадает из меню и строки меню; GLM нужен ещё и ключ.
    @Test func providersFollowBlocksAndKey() {
        #expect(LimitsProvider.available(blocks: LimitsBlock.allCases, hasGLMKey: true) == [.claude, .glm])
        #expect(LimitsProvider.available(blocks: LimitsBlock.allCases, hasGLMKey: false) == [.claude])
        #expect(LimitsProvider.available(blocks: [.glmLimits, .claudeCost], hasGLMKey: true) == [.glm])
        #expect(LimitsProvider.available(blocks: [.claudeCost], hasGLMKey: true).isEmpty)

        #expect(LimitsProvider.resolve(.glm, available: [.claude, .glm]) == .glm)
        #expect(LimitsProvider.resolve(.glm, available: [.claude]) == .claude)
        #expect(LimitsProvider.resolve(.claude, available: []) == nil)
    }
}
