// Рисует иконку Northy 1024×1024 через CoreGraphics: тёмный скруглённый квадрат,
// силуэт выреза сверху и мягкое голубое свечение под ним. Без внешних ассетов.
// Запуск: swift scripts/make-icon.swift [путь-к-PNG]

import CoreGraphics
import Foundation
import ImageIO

let canvasSize = 1024
let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "scripts/AppIcon1024.png"

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else {
    fatalError("Не удалось создать графический контекст")
}

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Холст прозрачный — за пределами скруглённого квадрата ничего не рисуем
// (стандартный отступ macOS-иконок).
context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

let margin = CGFloat(canvasSize) * 0.10
let side = CGFloat(canvasSize) - margin * 2
let squareRect = CGRect(x: margin, y: margin, width: side, height: side)
let squareRadius = side * 0.23

let backgroundColor = CGColor(red: 0x1a / 255.0, green: 0x1a / 255.0, blue: 0x1c / 255.0, alpha: 1)
let notchColor = CGColor(red: 0x0d / 255.0, green: 0x0d / 255.0, blue: 0x0e / 255.0, alpha: 1)
let accent = (r: CGFloat(0x0A) / 255.0, g: CGFloat(0x84) / 255.0, b: CGFloat(0xFF) / 255.0)

context.addPath(roundedRectPath(squareRect, radius: squareRadius))
context.setFillColor(backgroundColor)
context.fillPath()

context.saveGState()
context.addPath(roundedRectPath(squareRect, radius: squareRadius))
context.clip()

// Силуэт выреза — вплотную к верхнему краю квадрата, скруглены только нижние углы.
let notchWidth = side * 0.34
let notchHeight = side * 0.14
let notchRect = CGRect(
    x: squareRect.midX - notchWidth / 2,
    y: squareRect.maxY - notchHeight,
    width: notchWidth,
    height: notchHeight
)
let notchCornerRadius = notchHeight * 0.4
let notchPath = CGMutablePath()
notchPath.move(to: CGPoint(x: notchRect.minX, y: notchRect.maxY))
notchPath.addLine(to: CGPoint(x: notchRect.minX, y: notchRect.minY + notchCornerRadius))
notchPath.addArc(
    center: CGPoint(x: notchRect.minX + notchCornerRadius, y: notchRect.minY + notchCornerRadius),
    radius: notchCornerRadius,
    startAngle: .pi,
    endAngle: .pi * 1.5,
    clockwise: false
)
notchPath.addLine(to: CGPoint(x: notchRect.maxX - notchCornerRadius, y: notchRect.minY))
notchPath.addArc(
    center: CGPoint(x: notchRect.maxX - notchCornerRadius, y: notchRect.minY + notchCornerRadius),
    radius: notchCornerRadius,
    startAngle: .pi * 1.5,
    endAngle: 0,
    clockwise: false
)
notchPath.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY))
notchPath.closeSubpath()

context.addPath(notchPath)
context.setFillColor(notchColor)
context.fillPath()

// Мягкое свечение акцентным цветом из-под выреза — радиальный градиент без
// жёстких границ (линейный в обрезанном прямоугольнике выглядел как ещё один
// плоский синий блок, а не как свет). Растянут по вертикали лёгким масштабом
// контекста, чтобы бежать вниз, а не расплываться в стороны кругом.
let glowCenter = CGPoint(x: squareRect.midX, y: notchRect.minY)
let glowRadius = side * 0.30

context.saveGState()
context.translateBy(x: glowCenter.x, y: glowCenter.y)
context.scaleBy(x: 1, y: 1.7)
context.translateBy(x: -glowCenter.x, y: -glowCenter.y)

let gradientColors = [
    CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 0.4),
    CGColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 0.0)
] as CFArray
guard let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0, 1]) else {
    fatalError("Не удалось создать градиент")
}
context.drawRadialGradient(
    gradient,
    startCenter: glowCenter,
    startRadius: 0,
    endCenter: glowCenter,
    endRadius: glowRadius,
    options: []
)
context.restoreGState()

context.restoreGState()

guard let cgImage = context.makeImage() else {
    fatalError("Не удалось получить изображение из контекста")
}

let outputURL = URL(fileURLWithPath: outputPath)
guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("Не удалось создать место назначения PNG")
}
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Не удалось сохранить PNG")
}

print("Иконка сохранена: \(outputURL.path)")
