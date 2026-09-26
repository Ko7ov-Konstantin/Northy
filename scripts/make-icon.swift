// Рисует иконку Northy 1024×1024 через CoreGraphics: тёмный скруглённый квадрат с
// мягким северным сиянием цветов вкладок, в центре — знак Northy: кольцо цветов
// лимитов с «островком» выреза сверху (как значок в строке меню). Без внешних ассетов.
// Запуск: swift scripts/make-icon.swift [путь-к-PNG]

import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "scripts/AppIcon1024.png"

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("Не удалось создать графический контекст") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func glow(_ center: CGPoint, radius: CGFloat, _ c: UInt32, _ alpha: CGFloat) {
    ctx.drawRadialGradient(gradient([color(c, alpha), color(c, 0)], [0, 1]),
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// Цвета — как в приложении: sky, violet, rose, amber.
let sky: UInt32 = 0x61C2FF, violet: UInt32 = 0xB885FF, rose: UInt32 = 0xFF809E, amber: UInt32 = 0xFFA847

ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
let margin = CGFloat(size) * 0.10
let side = CGFloat(size) - margin * 2
let square = CGRect(x: margin, y: margin, width: side, height: side)
let squarePath = CGPath(roundedRect: square, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)

// Тень под квадратом.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(squarePath)
ctx.setFillColor(color(0x0B0C10))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squarePath)
ctx.clip()

// Фон: почти чёрный с лёгкой синевой сверху.
ctx.drawLinearGradient(gradient([color(0x1A1D26), color(0x08090C)], [0, 1]),
                       start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])

// Северное сияние — мягкие пятна цветов за знаком.
let c = CGPoint(x: square.midX, y: square.midY - side * 0.03)
glow(CGPoint(x: c.x - side * 0.22, y: c.y + side * 0.18), radius: side * 0.55, sky, 0.30)
glow(CGPoint(x: c.x + side * 0.26, y: c.y + side * 0.05), radius: side * 0.50, violet, 0.26)
glow(CGPoint(x: c.x + side * 0.05, y: c.y - side * 0.30), radius: side * 0.50, amber, 0.20)

// Кольцо: конический градиент цветов по кругу, свечение — несколько всё более
// широких и прозрачных колец (размытия в CoreGraphics нет).
let ringRadius = side * 0.265
let ringWidth = side * 0.075
let ringStops: [UInt32] = [sky, violet, rose, amber, sky]
func mix(_ t: CGFloat) -> CGColor {
    let scaled = t * CGFloat(ringStops.count - 1)
    let i = min(Int(scaled), ringStops.count - 2)
    let f = scaled - CGFloat(i)
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 0xff) / 255 }
    let a = ringStops[i], b = ringStops[i + 1]
    return CGColor(red: ch(a, 16) + (ch(b, 16) - ch(a, 16)) * f,
                   green: ch(a, 8) + (ch(b, 8) - ch(a, 8)) * f,
                   blue: ch(a, 0) + (ch(b, 0) - ch(a, 0)) * f, alpha: 1)
}
// Конический градиент один раз — непрозрачными секторами в отдельную картинку.
let conic: CGImage = {
    let layer = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let segments = 720
    layer.setShouldAntialias(false)
    let r = CGFloat(size)
    for s in 0..<segments {
        let t = CGFloat(s) / CGFloat(segments)
        let a0 = .pi / 2 - t * 2 * .pi
        let a1 = .pi / 2 - (t + 1.5 / CGFloat(segments)) * 2 * .pi
        layer.move(to: c)
        layer.addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
        layer.closePath()
        layer.setFillColor(mix(t))
        layer.fillPath()
    }
    return layer.makeImage()!
}()
func drawRing(width: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addArc(center: c, radius: ringRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.setLineWidth(width)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.draw(conic, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
}
// Свечение — мягкие пятна вдоль кольца, каждое своего цвета.
for s in 0..<72 {
    let t = CGFloat(s) / 72
    let angle = .pi / 2 - t * 2 * .pi
    let p = CGPoint(x: c.x + cos(angle) * ringRadius, y: c.y + sin(angle) * ringRadius)
    let col = mix(t)
    ctx.drawRadialGradient(gradient([col.copy(alpha: 0.12)!, col.copy(alpha: 0)!], [0, 1]),
                           startCenter: p, startRadius: 0, endCenter: p, endRadius: ringWidth * 2.4, options: [])
}
drawRing(width: ringWidth, alpha: 1)

// Блик по верхней половине кольца — «стекло, освещённое сверху».
ctx.saveGState()
ctx.setLineWidth(ringWidth * 0.35)
ctx.setStrokeColor(color(0xFFFFFF, 0.28))
ctx.addArc(center: c, radius: ringRadius + ringWidth * 0.22, startAngle: .pi * 0.95, endAngle: .pi * 0.05, clockwise: true)
ctx.strokePath()
ctx.restoreGState()

// «Островок» выреза: свисает внутрь кольца с его верхнего края, обрезан по кругу.
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - ringRadius - ringWidth / 2, y: c.y - ringRadius - ringWidth / 2,
                          width: (ringRadius + ringWidth / 2) * 2, height: (ringRadius + ringWidth / 2) * 2))
ctx.clip()
let islandWidth = ringRadius * 0.9
let islandHeight = ringRadius * 0.5
let island = CGRect(x: c.x - islandWidth / 2, y: c.y + ringRadius - islandHeight, width: islandWidth, height: islandHeight + ringWidth)
let islandPath = CGPath(roundedRect: island, cornerWidth: islandHeight * 0.5, cornerHeight: islandHeight * 0.5, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: color(0x000000, 0.7))
ctx.addPath(islandPath)
ctx.setFillColor(color(0x030304))
ctx.fillPath()
ctx.restoreGState()
// Камера в островке — тёмная линза с синим бликом.
let lens = CGPoint(x: c.x + islandWidth * 0.26, y: island.minY + islandHeight * 0.48)
let lensRadius = islandHeight * 0.13
ctx.addEllipse(in: CGRect(x: lens.x - lensRadius, y: lens.y - lensRadius, width: lensRadius * 2, height: lensRadius * 2))
ctx.setFillColor(color(0x10131C))
ctx.fillPath()
glow(CGPoint(x: lens.x - lensRadius * 0.3, y: lens.y + lensRadius * 0.3), radius: lensRadius * 0.8, 0x4A7BFF, 0.7)
ctx.restoreGState()

// Тонкая светлая кромка по краю квадрата сверху.
ctx.addPath(squarePath)
ctx.setLineWidth(4)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)], [0, 0.5]),
                       start: CGPoint(x: 0, y: square.maxY), end: CGPoint(x: 0, y: square.minY), options: [])
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("Не удалось сохранить PNG") }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Не удалось сохранить PNG") }
print("Иконка сохранена: \(outputPath)")
