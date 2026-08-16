import AppKit

enum NotchGeometry {

    static let fallbackSize = CGSize(width: 200, height: 32)
    static let collapsedExtraHeight: CGFloat = 4
    /// Размер видимого содержимого развёрнутой панели — без учёта отступа под вырез.
    static let expandedContentSize = CGSize(width: 590, height: 320)

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// Высота физического выреза — верхний отступ, под который прячется контент.
    /// 0, если на экране нет выреза (фолбэк-режим).
    static func notchHeight() -> CGFloat {
        notchScreen?.safeAreaInsets.top ?? 0
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

    /// Свёрнутый фрейм — только мёртвая зона выреза плюс небольшой запас вниз.
    static func collapsedFrame() -> CGRect {
        if let screen = notchScreen, let notch = notchRect(on: screen) {
            return CGRect(
                x: notch.minX,
                y: notch.maxY - notch.height - collapsedExtraHeight,
                width: notch.width,
                height: notch.height + collapsedExtraHeight
            )
        }
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: fallbackSize.width, height: fallbackSize.height)
        }
        let x = screen.frame.midX - fallbackSize.width / 2
        let y = screen.frame.maxY - fallbackSize.height
        return CGRect(x: x, y: y, width: fallbackSize.width, height: fallbackSize.height)
    }

    /// Развёрнутый фрейм — по центру выреза, верхняя кромка совпадает с верхом экрана.
    /// Высота = высота содержимого + высота выреза, чтобы контент не прятался под чёлкой.
    static func expandedFrame() -> CGRect {
        let centerX: CGFloat
        let screenTop: CGFloat

        if let notchScreen, let notch = notchRect(on: notchScreen) {
            centerX = notch.midX
            screenTop = notchScreen.frame.maxY
        } else if let main = NSScreen.main {
            centerX = main.frame.midX
            screenTop = main.frame.maxY
        } else {
            let size = expandedContentSize
            return CGRect(origin: .zero, size: size)
        }

        let height = expandedContentSize.height + notchHeight()
        let x = centerX - expandedContentSize.width / 2
        let y = screenTop - height
        return CGRect(x: x, y: y, width: expandedContentSize.width, height: height)
    }
}
