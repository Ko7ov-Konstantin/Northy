import Foundation
import Testing
@testable import Northy

@MainActor
/// Подменю «Страница статуса»: компоненты публичного status.claude.com.
struct StatusPageTests {

    @Test func parsesTopLevelComponents() throws {
        let json = """
        {"components":[
          {"id":"1","name":"claude.ai","status":"operational","group":false,"group_id":null,"only_show_if_degraded":false},
          {"id":"2","name":"Claude Code","status":"partial_outage","group":false,"group_id":null},
          {"id":"3","name":"Группа","status":"operational","group":true,"group_id":null},
          {"id":"4","name":"Вложенный","status":"operational","group":false,"group_id":"3"},
          {"id":"5","name":"Скрытый при норме","status":"operational","group":false,"only_show_if_degraded":true},
          {"id":"6","name":"Новый статус","status":"something_new","group":false}
        ]}
        """
        let components = try StatusPage.parse(Data(json.utf8))
        #expect(components.map(\.name) == ["claude.ai", "Claude Code", "Новый статус"])
        #expect(components[0].status == .operational)
        #expect(components[1].status == .partialOutage)
        #expect(components[2].status == .unknown)
    }

    @Test func statusTitlesInRussian() {
        #expect(StatusPage.Status.operational.title == "Работает")
        #expect(StatusPage.Status.degradedPerformance.title == "Замедление")
        #expect(StatusPage.Status.partialOutage.title == "Частичный сбой")
        #expect(StatusPage.Status.majorOutage.title == "Серьёзный сбой")
        #expect(StatusPage.Status.underMaintenance.title == "Обслуживание")
    }

    /// Строка вверху подменю — видно, насколько свежие статусы.
    @Test func freshnessLine() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(StatusPage.freshness(updatedAt: nil, isLoading: true, failed: false, now: now) == "Обновляется…")
        #expect(StatusPage.freshness(updatedAt: nil, isLoading: false, failed: true, now: now) == "Не удалось загрузить статус")
        #expect(StatusPage.freshness(updatedAt: now - 10, isLoading: false, failed: false, now: now) == "Обновлено только что")
        #expect(StatusPage.freshness(updatedAt: now - 300, isLoading: false, failed: false, now: now) == "Обновлено 5 мин назад")
        #expect(StatusPage.freshness(updatedAt: now - 300, isLoading: false, failed: true, now: now)
                == "Не удалось обновить · данные 5 мин назад")
        #expect(StatusPage.freshness(updatedAt: now - 300, isLoading: true, failed: false, now: now)
                == "Обновляется… · данные 5 мин назад")
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) { try StatusPage.parse(Data("<html>".utf8)) }
    }
}
