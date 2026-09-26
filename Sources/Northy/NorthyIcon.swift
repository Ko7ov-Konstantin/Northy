import AppKit

/// Знак Northy для строки меню: кольцо — «экран», сверху внутри висит
/// «островок», как у выреза. Шаблонная картинка — macOS сама красит её под
/// светлую и тёмную строку меню; рисуется кодом, поэтому чёткая на любом экране.
enum NorthyIcon {
    static func menuBarImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let lineWidth = size * 0.1
            let ringRect = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let ring = NSBezierPath(ovalIn: ringRect)
            ring.lineWidth = lineWidth
            NSColor.black.setStroke()
            ring.stroke()

            // «Островок» свисает внутрь кольца с его верхнего края — как панель
            // из выреза; обрезан по кругу, поэтому сливается с кольцом.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: ringRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)).addClip()
            let islandWidth = size * 0.5
            let islandHeight = size * 0.3
            let island = NSRect(
                x: rect.midX - islandWidth / 2,
                y: ringRect.maxY - islandHeight,
                width: islandWidth,
                height: islandHeight + lineWidth
            )
            let radius = size * 0.12
            NSColor.black.setFill()
            NSBezierPath(roundedRect: island, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Northy"
        return image
    }
}
