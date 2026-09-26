// Хост-раннер для swift-testing в среде без Xcode (только CommandLineTools).
// На CLT `swift test` собирает .xctest-бандл, но не исполняет его: системного
// раннера xctest нет. Здесь бандл загружается через dlopen, а входная точка
// Swift Testing обнаруживает тесты по метаданным всех загруженных образов.
// Запуск: scripts/run-tests.sh
import Foundation
import Testing

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("Использование: test-host <путь к бинарю .xctest-бандла>\n".data(using: .utf8)!)
    exit(2)
}

let bundleBinary = CommandLine.arguments[1]
guard dlopen(bundleBinary, RTLD_NOW | RTLD_LOCAL) != nil else {
    FileHandle.standardError.write("dlopen failed: \(String(cString: dlerror()))\n".data(using: .utf8)!)
    exit(3)
}

// Управление никогда не возвращается: точка входа сама печатает результаты
// и завершает процесс с нужным кодом.
await Testing.__swiftPMEntryPoint() as Never
