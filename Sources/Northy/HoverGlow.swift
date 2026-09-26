import SwiftUI

extension EnvironmentValues {
    /// false, пока остров свёрнут или вкладка скрыта: застрявший isHovering не рисуется.
    @Entry var hoverGlowEnabled: Bool = true
}

enum Hover {
    static let enter = Animation.snappy(duration: 0.2)
    static let exit = Animation.smooth(duration: 0.16)
    static let fade = Animation.easeOut(duration: 0.15)
    static let reduced = Animation.easeOut(duration: 0.12)
    static let press = Animation.snappy(duration: 0.12)
}

/// Подсветка при наведении из трёх слоёв: ореол цвета элемента за формой,
/// кромка «стекла, освещённого сверху» и лёгкий подъём (только отрисовка, не раскладка).
struct HoverGlowStyle {
    var tint: Color = .white
    var scale: CGFloat = 1.06
    var aura: Double = 0.28
    var halo: CGFloat = 4
    var wash: Double = 0
    /// Свет от левого края (от иконки строки) к середине.
    var lead: Double = 0
    var leadStart: UnitPoint = .leading
    var leadEnd: UnitPoint = .trailing
    var sheen: Double = 0
    var rim: Color? = nil
    var rimTop: Double = 0.5
    var rimBottom: Double = 0.06
    var rimWidth: CGFloat = 0.75

    /// nil — нейтральная кнопка: светится белым и тише цветных.
    static func icon(_ tint: Color?) -> Self {
        Self(tint: tint ?? .white, scale: 1.08, aura: tint == nil ? 0.10 : 0.26, halo: 3, rim: .white, rimTop: 0.26, rimBottom: 0.03)
    }
    static func capsule(_ tint: Color) -> Self {
        Self(tint: tint, scale: 1.04, aura: 0.24, halo: 4, wash: 0.07, rimTop: 0.55)
    }
    static func accentCircle(_ tint: Color) -> Self {
        Self(tint: tint, scale: 1.10, aura: 0.35, halo: 4, wash: 0.12, rimTop: 0.6)
    }
    static func tile(_ tint: Color) -> Self {
        Self(tint: tint, scale: 1.08, aura: 0.42, halo: 5, rimTop: 0)
    }
    static let destructive = Self(tint: Theme.danger, scale: 1.04, aura: 0.45, halo: 4, rim: .white, rimTop: 0.45, rimBottom: 0.08)
    /// Для строк в ScrollView: без подъёма и ореола — иначе края обрезаются и свет
    /// залезает на соседей. Строка светится изнутри цветом своего типа.
    static func surface(_ tint: Color) -> Self {
        Self(tint: tint, scale: 1, aura: 0, lead: 0.16, sheen: 0.05, rimTop: 0.5, rimBottom: 0.06, rimWidth: 0.9)
    }
    /// Плитка в сетке: как строка, но свет сверху — от иконки файла.
    static func plate(_ tint: Color) -> Self {
        var style = surface(tint)
        style.leadStart = .top
        style.leadEnd = .bottom
        return style
    }
    static let glyph = Self(scale: 1.15, aura: 0, rimTop: 0)
}

/// Все слои существуют только под курсором — в покое элемент не рисует ничего лишнего.
struct HoverGlow<S: InsettableShape>: ViewModifier {
    var isHovering: Bool
    var shape: S
    var style: HoverGlowStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.hoverGlowEnabled) private var enabled

    private var lit: Bool { isHovering && enabled }
    private var fade: Animation { reduceMotion ? Hover.reduced : Hover.fade }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if lit {
                        if style.aura > 0 {
                            shape.fill(style.tint.opacity(style.aura)).blur(radius: style.halo)
                        }
                        if style.wash > 0 {
                            shape.fill(style.tint.opacity(style.wash))
                        }
                        if style.lead > 0 {
                            shape.fill(LinearGradient(
                                stops: [
                                    .init(color: style.tint.opacity(style.lead), location: 0),
                                    .init(color: style.tint.opacity(style.lead * 0.3), location: 0.4),
                                    .init(color: .clear, location: 0.8),
                                ],
                                startPoint: style.leadStart,
                                endPoint: style.leadEnd
                            ))
                        }
                        if style.sheen > 0 {
                            shape.fill(LinearGradient(colors: [.white.opacity(style.sheen), .clear], startPoint: .top, endPoint: .center))
                        }
                    }
                }
                .animation(fade, value: lit)
                .allowsHitTesting(false)
            }
            .overlay {
                ZStack {
                    if lit && style.rimTop > 0 {
                        let rim = style.rim ?? style.tint
                        shape.strokeBorder(
                            LinearGradient(colors: [rim.opacity(style.rimTop), rim.opacity(style.rimBottom)], startPoint: .top, endPoint: .bottom),
                            lineWidth: contrast == .increased ? style.rimWidth * 2 : style.rimWidth
                        )
                    }
                }
                .animation(fade, value: lit)
                .allowsHitTesting(false)
            }
            // Анимация подъёма ограничена scaleEffect — не протекает в numericText и смену подписей.
            .animation(lit ? Hover.enter : Hover.exit) {
                $0.scaleEffect(lit && !reduceMotion ? style.scale : 1)
            }
    }
}

/// Вариант со своим onHover. contentShape ставить до него — зона наведения не растёт с подъёмом.
struct HoverGlowTracking<S: InsettableShape>: ViewModifier {
    var shape: S
    var style: HoverGlowStyle
    @State private var isHovering = false
    @Environment(\.hoverGlowEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .modifier(HoverGlow(isHovering: isHovering, shape: shape, style: style))
            .onHover { isHovering = $0 }
            .onChange(of: enabled) { _, on in if !on { isHovering = false } }
    }
}

extension View {
    func hoverGlow<S: InsettableShape>(_ isHovering: Bool, in shape: S, style: HoverGlowStyle) -> some View {
        modifier(HoverGlow(isHovering: isHovering, shape: shape, style: style))
    }

    func hoverGlow<S: InsettableShape>(in shape: S, style: HoverGlowStyle) -> some View {
        modifier(HoverGlowTracking(shape: shape, style: style))
    }
}

/// Для подписей, которые при наведении ещё и меняют цвет, а своего состояния наведения не имеют.
struct HoverReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var isHovering = false
    @Environment(\.hoverGlowEnabled) private var enabled

    var body: some View {
        content(isHovering && enabled)
            .onHover { isHovering = $0 }
            .onChange(of: enabled) { _, on in if !on { isHovering = false } }
    }
}

/// Где курсор над строкой. Читает только слой пятна — body строки
/// на каждое движение мыши не пересчитывается.
@Observable
final class PointerSpot {
    var location: CGPoint?
}

/// Пятно света цвета поверхности, которое идёт за курсором.
struct PointerSheen<S: Shape>: View {
    var spot: PointerSpot
    var shape: S
    var tint: Color = .white
    var radius: CGFloat = 150

    var body: some View {
        if let location = spot.location {
            GeometryReader { proxy in
                RadialGradient(
                    colors: [tint.opacity(0.13), tint.opacity(0.04), .clear],
                    center: UnitPoint(x: location.x / max(proxy.size.width, 1), y: location.y / max(proxy.size.height, 1)),
                    startRadius: 0,
                    endRadius: radius
                )
            }
            .clipShape(shape)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Hover.press) {
                $0.scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            }
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    static func pressable(scale: CGFloat) -> PressableButtonStyle { PressableButtonStyle(pressedScale: scale) }
}

/// Сегменты-капсулы вместо системного .segmented: тот в тёмном острове синий и
/// показывает текстовый курсор. Цвета семантические и клик через onTapGesture —
/// работает и в панели, и внутри меню статус-бара.
struct ChipPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var tint: Color
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Chip(title: title(option), isOn: selection == option, tint: tint) {
                    withAnimation(Theme.tabSpring) { selection = option }
                }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct Chip: View {
    let title: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        HoverReader { hovering in
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(tint.opacity(isOn ? (hovering ? 0.28 : 0.22) : (hovering ? 0.12 : 0))))
                .contentShape(Capsule())
                .animation(Hover.fade, value: hovering)
        }
        .onTapGesture(perform: action)
        .pointerStyle(.link)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
