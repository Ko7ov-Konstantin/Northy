import Testing
@testable import Northy

@MainActor
/// Цвет заполнения лимита: бледный в начале, насыщенный и красный к 100%.
struct UsageTintTests {

    @Test func mutedAtStartAndFullAtLimit() {
        #expect(UsageTint.vividness(percent: 0) <= 0.5)
        #expect(UsageTint.vividness(percent: 100) == 1)
    }

    @Test func vividnessNeverDropsAsUsageGrows() {
        let steps = stride(from: 0.0, through: 100, by: 10).map(UsageTint.vividness)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(UsageTint.vividness(percent: 10) < UsageTint.vividness(percent: 30))
    }

    @Test func ownColorInFirstQuarter() {
        #expect(UsageTint.alarm(percent: 0) == 0)
        #expect(UsageTint.alarm(percent: 10) == 0)
        #expect(UsageTint.alarm(percent: 25) == 0)
    }

    @Test func redderAtEachQuarter() {
        let quarters = [25.0, 50, 75, 100].map(UsageTint.alarm)
        #expect(zip(quarters, quarters.dropFirst()).allSatisfy { $0 < $1 })
        #expect(UsageTint.alarm(percent: 50) < 0.5)
        #expect(UsageTint.alarm(percent: 100) == 1)
    }

    @Test func redChangesSmoothlyBetweenQuarters() {
        let steps = stride(from: 0.0, through: 100, by: 5).map(UsageTint.alarm)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 <= $1 && $1 - $0 < 0.1 })
    }

    @Test func clampsOutOfRange() {
        #expect(UsageTint.vividness(percent: -20) == UsageTint.vividness(percent: 0))
        #expect(UsageTint.vividness(percent: 140) == 1)
        #expect(UsageTint.alarm(percent: 140) == 1)
    }

    @Test func remainingColorIsFullWhileLimitIsUntouched() {
        #expect(UsageTint.remainingVividness(percent: 0) == 1)
    }

    @Test func remainingColorFadesAsLimitRunsOut() {
        let steps = stride(from: 0.0, through: 100, by: 10).map(UsageTint.remainingVividness)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 > $1 && $0 - $1 < 0.1 })
        #expect(UsageTint.remainingVividness(percent: 100) < 0.5)
        #expect(UsageTint.remainingVividness(percent: 140) == UsageTint.remainingVividness(percent: 100))
    }
}
