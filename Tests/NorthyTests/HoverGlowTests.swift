import Testing
@testable import Northy

@MainActor
struct HoverGlowTests {

    /// Строки буфера во всю ширину ScrollView: любой подъём обрезает края,
    /// а ореол залезает на соседние строки.
    @Test func surfacesInScrollViewOnlyLightUp() {
        #expect(HoverGlowStyle.surface.scale == 1)
        #expect(HoverGlowStyle.surface.aura == 0)
        #expect(HoverGlowStyle.surface.wash == 0)
    }

    /// Крестик в поле поиска сидит вплотную к тексту — без ореола и кромки.
    @Test func inlineGlyphHasNoHalo() {
        #expect(HoverGlowStyle.glyph.aura == 0)
        #expect(HoverGlowStyle.glyph.rimTop == 0)
    }

    /// Нейтральные кнопки светятся тише цветных (выход, корзина).
    @Test func neutralIconsGlowSofterThanColored() {
        let neutral = HoverGlowStyle.icon(Theme.primaryText, neutral: true)
        let colored = HoverGlowStyle.icon(Theme.danger, neutral: false)
        #expect(neutral.aura < colored.aura)
        #expect(neutral.scale == colored.scale)
    }
}
