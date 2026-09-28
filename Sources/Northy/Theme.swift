import SwiftUI

/// Палитра «острова»: панель всегда тёмная, чтобы сливаться с вырезом,
/// у каждой вкладки свой цвет-акцент.
enum Theme {
    static let islandTop = Color.black
    static let islandBottom = Color(red: 0.06, green: 0.06, blue: 0.075)
    static let edge = Color.white.opacity(0.09)

    static let card = Color.white.opacity(0.055)
    static let cardHover = Color.white.opacity(0.10)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.52)
    static let tertiaryText = Color.white.opacity(0.32)

    static let sky = Color(red: 0.38, green: 0.76, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.66, blue: 0.28)
    static let violet = Color(red: 0.72, green: 0.52, blue: 1.0)
    static let mint = Color(red: 0.36, green: 0.9, blue: 0.62)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let rose = Color(red: 1.0, green: 0.5, blue: 0.62)

    static let expandSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let collapseAnimation = Animation.smooth(duration: 0.3)
    static let tabSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

extension PanelTab {
    var tint: Color {
        switch self {
        case .clipboard: Theme.sky
        case .files: Theme.amber
        case .translator: Theme.violet
        case .limits: Theme.rose
        case .music: Theme.mint
        }
    }
}

/// Контур «острова»: сверху — вогнутые «ушки», которыми панель вытекает из
/// кромки экрана, как продолжение выреза; снизу — скруглённые углы.
nonisolated struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4, rect.height / 2)
        let bottom = min(bottomRadius, (rect.width - 2 * top) / 2, rect.height - top)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Плоская кнопка-иконка в круге: при наведении приподнимается и светится
/// своим цветом (нейтральные — белым, выход и корзина — красным).
struct IconButton: View {
    let systemName: String
    var tint: Color = Theme.secondaryText
    /// nil — нейтральная кнопка: белеет и светится белым; цвет — светится им.
    var hoverTint: Color? = nil
    var size: CGFloat = 26
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.hoverGlowEnabled) private var glowEnabled

    var body: some View {
        let lit = isHovering && glowEnabled
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(lit ? (hoverTint ?? Theme.primaryText) : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(lit ? 0.12 : 0.0)))
                .contentShape(Circle())
                .hoverGlow(lit, in: Circle(), style: .icon(hoverTint))
        }
        .buttonStyle(.pressable)
        .handCursor()
        .onHover { isHovering = $0 }
        .onChange(of: glowEnabled) { _, on in if !on { isHovering = false } }
        .animation(.easeOut(duration: 0.15), value: lit)
        .help(help)
    }
}

/// «Очистить» в два нажатия: первое превращает кнопку в красное
/// подтверждение, второе (в течение 3 с) — выполняет.
struct ConfirmClearButton: View {
    let action: () -> Void

    @State private var isArmed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isArmed {
                Button {
                    disarmTask?.cancel()
                    isArmed = false
                    action()
                } label: {
                    Label("Очистить?", systemImage: "trash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.danger.opacity(0.85)))
                        .contentShape(Capsule())
                        .hoverGlow(in: Capsule(), style: .destructive)
                }
                .buttonStyle(.pressable)
                .handCursor()
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                IconButton(systemName: "trash", hoverTint: Theme.danger, help: "Очистить") {
                    isArmed = true
                    disarmTask?.cancel()
                    disarmTask = Task {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        withAnimation(Theme.tabSpring) { isArmed = false }
                    }
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(Theme.tabSpring, value: isArmed)
    }
}
