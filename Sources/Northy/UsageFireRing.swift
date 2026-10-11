import SwiftUI

/// Кольцо лимита во вкладке: градиент по месту на дуге, свечение и огонь на горячем хвосте.
struct UsageFireRing: View {
    let window: UsageWindow
    let lineWidth: CGFloat

    var body: some View {
        let share = window.percent / 100
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().stroke(Color.black.opacity(0.55), lineWidth: lineWidth * 1.5)
                Circle().stroke(Color.white.opacity(0.06), lineWidth: lineWidth * 1.5)
                if share > 0 {
                    arc(share, diameter: diameter).blur(radius: lineWidth * 1.1).opacity(0.75)
                    arc(share, diameter: diameter).blur(radius: lineWidth * 0.4).opacity(0.6)
                    arc(share, diameter: diameter)
                    Circle().trim(from: 0, to: share)
                        .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: lineWidth * 0.28, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .blur(radius: lineWidth * 0.12)
                        .blendMode(.plusLighter)
                }
            }
            .overlay {
                if window.percent > UsageFlames.startsAt {
                    let canvas = diameter * 1.8
                    UsageFlames(window: window, lineWidth: lineWidth, length: diameter * .pi) { mark in
                        let angle = (mark * 3.6 - 90) * .pi / 180
                        let normal = CGVector(dx: cos(angle), dy: sin(angle))
                        return (CGPoint(x: canvas / 2 + normal.dx * diameter / 2, y: canvas / 2 + normal.dy * diameter / 2), normal)
                    }
                    .frame(width: canvas, height: canvas)
                }
            }
        }
    }

    /// Дуга со скруглёнными концами: у градиента по кругу штатное скругление
    /// залезает в цвет противоположного конца, поэтому концы — отдельными точками.
    private func arc(_ share: Double, diameter: CGFloat) -> some View {
        ZStack {
            Circle().trim(from: 0, to: share)
                .stroke(AngularGradient(gradient: window.gaugeGradient, center: .center), lineWidth: lineWidth)
                .rotationEffect(.degrees(-90))
            cap(window.gaugeColor(at: 0), diameter: diameter)
            cap(window.gaugeColor, diameter: diameter).rotationEffect(.degrees(360 * share))
        }
    }

    private func cap(_ color: Color, diameter: CGFloat) -> some View {
        Circle().fill(color).frame(width: lineWidth, height: lineWidth).offset(y: -diameter / 2)
    }
}

/// Пламя вдоль шкалы: высота языка зависит от места, как и цвет, — у отметки `startsAt`
/// едва тлеет, к 100% горит в полную силу. Форму шкалы задаёт `anchor`: точка на шкале
/// и направление «наружу» для отметки в процентах.
struct UsageFlames: View {
    typealias Anchor = (point: CGPoint, normal: CGVector)

    /// Отметка шкалы, с которой она начинает тлеть.
    static let startsAt = 40.0
    private static let dropsPerTongue = 6
    /// Шаг между языками и между искрами вдоль шкалы, в пунктах.
    private static let tongueSpacing = 2.4
    private static let sparkSpacing = 5.0
    /// Слои языка пламени от края к сердцевине: порог слияния капель и цвет.
    private static let layers: [(threshold: Double, color: Color)] = [
        (0.2, Color(red: 0.9, green: 0.12, blue: 0.04).opacity(0.6)),
        (0.4, Color(red: 1, green: 0.36, blue: 0.06)),
        (0.58, Color(red: 1, green: 0.62, blue: 0.14)),
        (0.76, Color(red: 1, green: 0.88, blue: 0.5)),
    ]

    let window: UsageWindow
    /// Толщина шкалы — от неё считается размер пламени.
    let lineWidth: CGFloat
    /// Длина всей шкалы в пунктах — от неё считается число языков.
    let length: CGFloat
    let anchor: (Double) -> Anchor

    private var burningLength: Double { length * (100 - Self.startsAt) / 100 }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, _ in
                var random = SeededRandom(state: UInt64(bitPattern: Int64(window.kind.hashValue)))
                let embers = (0..<Int(burningLength / Self.tongueSpacing)).flatMap { _ in tongue(time: time, random: &random) }

                var halo = context
                halo.blendMode = .plusLighter
                halo.addFilter(.blur(radius: lineWidth * 0.9))
                for ember in embers {
                    halo.fill(Path(ellipseIn: ember), with: .color(Color(red: 1, green: 0.35, blue: 0.08).opacity(0.1)))
                }
                // Размытые капли, обрезанные по порогу, сливаются в цельные языки;
                // чем выше порог, тем уже слой — так получается светлая сердцевина.
                var soft = context
                soft.addFilter(.blur(radius: lineWidth * 0.07))
                for layer in Self.layers {
                    soft.drawLayer { flame in
                        flame.addFilter(.alphaThreshold(min: layer.threshold, color: layer.color))
                        flame.addFilter(.blur(radius: lineWidth * 0.3))
                        flame.drawLayer { drops in
                            for ember in embers {
                                drops.fill(Path(ellipseIn: ember), with: .color(.white))
                            }
                        }
                    }
                }
                var glow = context
                glow.blendMode = .plusLighter
                for _ in 0..<Int(burningLength / Self.sparkSpacing) {
                    drawSpark(in: &glow, time: time, random: &random)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Жар на отметке шкалы: 0 у `startsAt`, 1 на 100%, с плавным разгоном.
    private static func heat(at mark: Double) -> Double {
        pow((mark - startsAt) / (100 - startsAt), 1.8)
    }

    /// Язык пламени — цепочка капель, которые непрерывно текут от шкалы к кончику и сужаются.
    /// Случайные числа берутся всегда в одном количестве, даже если язык не рисуется:
    /// иначе при смене процента остальные языки прыгали бы на новые места.
    private func tongue(time: TimeInterval, random: inout SeededRandom) -> [CGRect] {
        let mark = Self.startsAt + (100 - Self.startsAt) * random.next()
        let inward = random.next() > 0.85
        let reach = random.next() * random.next()
        let sway = random.next() - 0.5
        let phase = random.next() * 2 * .pi
        let pace = 0.5 + 0.7 * random.next()
        guard mark <= window.percent else { return [] }

        let heat = Self.heat(at: mark)
        // Изнутри кольца горит только раскалённый участок — иначе пламя закрывает цвет шкалы.
        let side: Double = inward && heat > 0.5 ? -1 : 1
        let flicker = 0.7 + 0.3 * sin(time * (2.5 + 3 * pace) + phase)
        let height = lineWidth * (1.8 + 5.5 * reach) * pow(heat, 0.8) * flicker
        let width = lineWidth * (0.42 + 0.18 * reach) * pow(heat, 0.45)
        let (point, outward) = anchor(mark)
        return (0..<Self.dropsPerTongue).map { drop in
            let along = (Double(drop) / Double(Self.dropsPerTongue) + time * pace + phase).truncatingRemainder(dividingBy: 1)
            let lean = (sin(phase + along * 4 - time * 3) * 0.3 + sway) * lineWidth * along * (0.3 + 0.7 * heat)
            let x = point.x + outward.dx * side * (lineWidth * 0.45 + along * height * 0.3) + lean
            let y = point.y + outward.dy * side * (lineWidth * 0.45 + along * height * 0.3) - along * height
            let size = width * (1 - along)
            return CGRect(x: x - size, y: y - size, width: size * 2, height: size * 2)
        }
    }

    private func drawSpark(in context: inout GraphicsContext, time: TimeInterval, random: inout SeededRandom) {
        let mark = Self.startsAt + (100 - Self.startsAt) * random.next()
        let rise = random.next()
        let drift = (random.next() - 0.5) * lineWidth * 1.8
        let size = lineWidth * (0.03 + 0.06 * random.next())
        let offset = random.next()
        let pace = 0.35 + 0.5 * random.next()
        guard mark <= window.percent else { return }

        let heat = Self.heat(at: mark)
        let reach = lineWidth * (1.5 + 4 * rise) * heat
        let life = (time * pace + offset).truncatingRemainder(dividingBy: 1)
        let (point, outward) = anchor(mark)
        let x = point.x + outward.dx * reach * 0.5 * life + drift * life * heat
        let y = point.y + outward.dy * reach * 0.5 * life - reach * life
        context.fill(
            Path(ellipseIn: CGRect(x: x - size, y: y - size, width: size * 2, height: size * 2)),
            with: .color(Color(red: 1, green: 0.62, blue: 0.3).opacity(0.85 * (1 - life) * heat))
        )
    }
}

/// Повторяемая последовательность: огонь одного кольца между кадрами не перемешивается.
private struct SeededRandom {
    var state: UInt64

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 33) / Double(1 << 31)
    }
}
