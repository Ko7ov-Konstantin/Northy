import AppKit
import SwiftUI

enum PanelTab: CaseIterable, Identifiable, Hashable {
    case clipboard, files, translator

    var id: Self { self }

    var title: String {
        switch self {
        case .clipboard: "Буфер"
        case .files: "Файлы"
        case .translator: "Переводчик"
        }
    }

    var icon: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .files: "folder"
        case .translator: "character.bubble"
        }
    }
}

struct PanelRootView: View {
    var uiState: PanelUIState
    var clipboardStore: ClipboardStore
    var shelfStore: ShelfStore

    var body: some View {
        // Единственное исключение из системной темы: полоса под физический вырез
        // всегда чёрная — и в развёрнутом, и в свёрнутом состоянии, в обеих темах,
        // чтобы визуально сливаться с настоящей чёлкой. Остальной фон — блюр рабочего
        // стола от NSVisualEffectView на AppKit-уровне (PanelController), сюда SwiftUI
        // фон не кладём — иначе поверх блюра лёг бы ещё один непрозрачный слой.
        Group {
            if uiState.isExpanded {
                VStack(spacing: 0) {
                    Color.black
                        .frame(height: uiState.topInset)

                    HStack(spacing: 0) {
                        SidebarView(selectedTab: Binding(
                            get: { uiState.selectedTab },
                            set: { uiState.selectedTab = $0 }
                        )) {
                            NSApp.terminate(nil)
                        }
                        Divider()
                            .overlay(Color.primary.opacity(0.12))
                        content
                    }
                }
            } else {
                // Свёрнутая панель — только мёртвая зона выреза, тоже чёрная.
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                topTrailingRadius: 0
            )
        )
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    private var content: some View {
        ZStack {
            // opacity(0) в ZStack не выключает hit-testing — скрытая вкладка сверху
            // перехватывала клики/drop у видимой. allowsHitTesting добивает это явно.
            tabLayer(.clipboard) { ClipboardView(store: clipboardStore) }
            tabLayer(.files) { ShelfView(store: shelfStore) }
            tabLayer(.translator) { TranslatorView() }
        }
        .animation(.easeOut(duration: 0.18), value: uiState.selectedTab)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Лёгкий fade + сдвиг по Y при смене вкладки — вью не пересоздаются (все
    /// четыре всегда в дереве), анимируются только opacity/offset.
    @ViewBuilder
    private func tabLayer<Content: View>(_ tab: PanelTab, @ViewBuilder content: () -> Content) -> some View {
        let isSelected = uiState.selectedTab == tab
        content()
            .opacity(isSelected ? 1 : 0)
            .offset(y: isSelected ? 0 : 6)
            .allowsHitTesting(isSelected)
    }
}
