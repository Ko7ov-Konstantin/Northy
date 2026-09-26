import Testing
@testable import Northy

@MainActor
struct HoverGlowTests {

    /// Строки буфера во всю ширину ScrollView: любой подъём обрезает края,
    /// а ореол залезает на соседние строки.
    @Test func surfacesInScrollViewOnlyLightUp() {
        let surface = HoverGlowStyle.surface(Theme.sky)
        #expect(surface.scale == 1)
        #expect(surface.aura == 0)
        #expect(surface.wash == 0)
        #expect(surface.lead > 0, "свет от иконки — внутри формы, наружу ничего")
        #expect(surface.tint == Theme.sky, "строка светится цветом своего типа")
    }

    /// Крестик в поле поиска сидит вплотную к тексту — без ореола и кромки.
    @Test func inlineGlyphHasNoHalo() {
        #expect(HoverGlowStyle.glyph.aura == 0)
        #expect(HoverGlowStyle.glyph.rimTop == 0)
    }

    /// Без цвета кнопка нейтральная и светится тише цветных (выход, корзина).
    @Test func neutralIconsGlowSofterThanColored() {
        let neutral = HoverGlowStyle.icon(nil)
        let colored = HoverGlowStyle.icon(Theme.danger)
        #expect(neutral.aura < colored.aura)
        #expect(neutral.scale == colored.scale)
        #expect(colored.tint == Theme.danger)
    }
}
