import AppKit

enum NotchGeometry {

    static let fallbackSize = CGSize(width: 200, height: 32)
    static let collapsedExtraHeight: CGFloat = 4
    /// Размер содержимого развёрнутой панели по умолчанию — без отступа под вырез.
    static let expandedContentSize = CGSize(width: 700, height: 300)
    /// Меньше — вкладки в «ухе» выреза перестают помещаться.
    static let minimumContentSize = CGSize(width: 680, height: 260)
    /// Текущий размер: пользователь растягивает панель за уголок, размер переживает перезапуск.
    static var contentSize: CGSize = storedContentSize(in: .standard)

    private static let contentSizeKey = "panel.contentSize"

    static func storedContentSize(in defaults: UserDefaults) -> CGSize {
        guard let stored = defaults.string(forKey: contentSizeKey) else { return expandedContentSize }
        let size = NSSizeFromString(stored)
        return size.width > 0 && size.height > 0 ? size : expandedContentSize
    }

    static func storeContentSize(_ size: CGSize, in defaults: UserDefaults) {
        defaults.set(NSStringFromSize(size), forKey: contentSizeKey)
    }

    /// Не меньше минимума и не больше экрана; целые точки — без дрожания при перетаскивании.
    static func clampedContentSize(_ size: CGSize, screen: CGRect?) -> CGSize {
        let maxWidth = screen.map { $0.width - 40 } ?? .greatestFiniteMagnitude
        let maxHeight = screen.map { ($0.height * 0.85).rounded() } ?? .greatestFiniteMagnitude
        return CGSize(
            width: min(max(size.width.rounded(), minimumContentSize.width), maxWidth),
            height: min(max(size.height.rounded(), minimumContentSize.height), maxHeight)
        )
    }

    /// Экран, на котором живёт панель (с вырезом, иначе главный).
    static var panelScreenFrame: CGRect? {
        (notchScreen ?? NSScreen.main)?.frame
    }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// Высота физического выреза — верхний отступ, под который прячется контент.
    /// 0, если на экране нет выреза (фолбэк-режим).
    static func notchHeight() -> CGFloat {
        notchScreen?.safeAreaInsets.top ?? 0
    }

    /// Ширина выреза; 0 без выреза.
    static func notchWidth() -> CGFloat {
        notchScreen.flatMap { notchRect(on: $0) }?.width ?? 0
    }

    /// Прямоугольник самого выреза в экранных координатах (низ = верх экрана минус высота выреза).
    private static func notchRect(on screen: NSScreen) -> CGRect? {
        guard
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        else { return nil }

        let height = screen.safeAreaInsets.top
        guard height > 0 else { return nil }

        let x = left.maxX
        let width = right.minX - x
        let screenTop = screen.frame.maxY
        return CGRect(x: x, y: screenTop - height, width: width, height: height)
    }

    /// Ширина левого «уха» шапки: панель центрирована по вырезу, поэтому слева от него
    /// ровно (ширина шапки − вырез) / 2, минус зазор до выреза. Без выреза — nil (ограничения нет).
    static func leftEarWidth(headerWidth: CGFloat, notchWidth: CGFloat, gap: CGFloat = 8) -> CGFloat? {
        guard notchWidth > 0 else { return nil }
        return max(0, (headerWidth - notchWidth) / 2 - gap)
    }

    /// Свёрнутый фрейм — только мёртвая зона выреза плюс небольшой запас вниз.
    static func collapsedFrame() -> CGRect {
        collapsedFrame(
            notch: notchScreen.flatMap { notchRect(on: $0) },
            fallbackScreen: NSScreen.main?.frame
        )
    }

    /// Чистая часть расчёта — тестируется без NSScreen.
    static func collapsedFrame(notch: CGRect?, fallbackScreen: CGRect?) -> CGRect {
        if let notch {
            return CGRect(
                x: notch.minX,
                y: notch.maxY - notch.height - collapsedExtraHeight,
                width: notch.width,
                height: notch.height + collapsedExtraHeight
            )
        }
        guard let screen = fallbackScreen else {
            return CGRect(origin: .zero, size: fallbackSize)
        }
        let x = screen.midX - fallbackSize.width / 2
        let y = screen.maxY - fallbackSize.height
        return CGRect(x: x, y: y, width: fallbackSize.width, height: fallbackSize.height)
    }

    /// Развёрнутый фрейм — по центру выреза, верхняя кромка совпадает с верхом экрана.
    /// Высота = высота содержимого + высота выреза, чтобы контент не прятался под чёлкой.
    static func expandedFrame() -> CGRect {
        let screen = panelScreenFrame
        return expandedFrame(
            notch: notchScreen.flatMap { notchRect(on: $0) },
            screen: screen,
            notchHeight: notchHeight(),
            contentSize: clampedContentSize(contentSize, screen: screen)
        )
    }

    /// Чистая часть расчёта — тестируется без NSScreen.
    static func expandedFrame(
        notch: CGRect?,
        screen: CGRect?,
        notchHeight: CGFloat,
        contentSize: CGSize = expandedContentSize
    ) -> CGRect {
        guard let screen else {
            return CGRect(origin: .zero, size: contentSize)
        }
        let centerX = notch?.midX ?? screen.midX
        let height = contentSize.height + notchHeight
        let x = centerX - contentSize.width / 2
        let y = screen.maxY - height
        return CGRect(x: x, y: y, width: contentSize.width, height: height)
    }
}
