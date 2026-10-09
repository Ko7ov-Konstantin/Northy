import Foundation
import Testing
@testable import Northy

/// Обновление цен по кнопке и по расписанию — без сети, с подменённым загрузчиком.
@MainActor
struct PriceRefreshTests {
    private final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var result: [String: TokenPricing.Rates]?
        var delay: Duration = .zero
        init(_ result: [String: TokenPricing.Rates]?) { self.result = result }
        var calls: Int { lock.withLock { count } }
        func call() async -> [String: TokenPricing.Rates]? {
            lock.withLock { count += 1 }
            try? await Task.sleep(for: delay)
            return result
        }
    }

    private let old = ["claude-old": TokenPricing.Rates(input: 1, output: 2)]
    private let new = ["claude-new": TokenPricing.Rates(input: 3, output: 4)]

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("prices-\(UUID().uuidString).json")
    }

    private func store(_ loader: Loader, file: URL, saved: Date? = nil) -> TokenStatsStore {
        if let saved { TokenPricing.write(.init(fetchedAt: saved, rates: old), to: file) }
        return TokenStatsStore(
            scanner: TokenUsageScanner(projectRoots: [FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)")]),
            downloadPrices: { await loader.call() },
            pricesURL: file
        )
    }

    @Test func manualRefreshSuccessReplacesPricesAndWritesFile() async {
        let url = file()
        let loader = Loader(new)
        let store = store(loader, file: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await store.refreshPricesNow(now: now)
        #expect(store.prices == new)
        #expect(store.pricesFetchedAt == now)
        #expect(!store.priceFetchFailed)
        #expect(TokenPricing.readSaved(from: url) == .init(fetchedAt: now, rates: new))
    }

    @Test func manualRefreshFailureKeepsOldPrices() async {
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let loader = Loader(nil)
        let store = store(loader, file: file(), saved: saved)
        await store.refreshPricesNow(now: saved + 100)
        #expect(store.prices == old)
        #expect(store.pricesFetchedAt == saved)
        #expect(store.priceFetchFailed)
    }

    @Test func manualRefreshIgnoresSchedule() async {
        let now = Date.now
        let loader = Loader(new)
        let store = store(loader, file: file(), saved: now - 60)
        await store.refreshPricesNow(now: now)
        #expect(loader.calls == 1)
        #expect(store.prices == new)
    }

    @Test func secondCallWhileFetchingDoesNothing() async {
        let loader = Loader(new)
        loader.delay = .milliseconds(200)
        let store = store(loader, file: file())
        async let first: Void = store.refreshPricesNow()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(store.isFetchingPrices)
        await store.refreshPricesNow()
        await first
        #expect(loader.calls == 1)
        #expect(!store.isFetchingPrices)
    }

    @Test func scheduleSkipsRepeatWithinDay() async {
        let loader = Loader(new)
        let store = store(loader, file: file())
        let now = Date.now
        await store.refresh(now: now)
        await store.priceTask?.value
        #expect(loader.calls == 1)
        await store.refresh(force: true, now: now + 3600)
        await store.priceTask?.value
        #expect(loader.calls == 1)
    }
}
