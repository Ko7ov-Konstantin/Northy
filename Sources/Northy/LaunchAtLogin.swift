import Foundation
import ServiceManagement

/// Автозапуск при входе в систему — SMAppService.mainApp (Объекты входа macOS).
@MainActor
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// Зарегистрировано, но macOS ждёт разрешения пользователя в настройках.
        case needsApproval
        /// Системе не удалось найти приложение (например, запущено не из «Программ»).
        case unavailable

        init(status: SMAppService.Status) {
            switch status {
            case .enabled: self = .enabled
            case .requiresApproval: self = .needsApproval
            case .notFound: self = .unavailable
            default: self = .disabled
            }
        }

        var isOn: Bool {
            self == .enabled || self == .needsApproval
        }

        var hint: String? {
            switch self {
            case .enabled, .disabled: nil
            case .needsApproval: "Разрешите Northy: Системные настройки → Основные → Объекты входа"
            case .unavailable: "Автозапуск доступен, когда Northy установлен в «Программы»"
            }
        }
    }

    static var state: State {
        State(status: SMAppService.mainApp.status)
    }

    /// Возвращает новое состояние; ошибку регистрации — текстом для настроек.
    static func set(_ enabled: Bool) -> (State, String?) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return (state, nil)
        } catch {
            return (state, error.localizedDescription)
        }
    }
}
