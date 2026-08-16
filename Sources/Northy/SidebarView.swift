import SwiftUI

struct SidebarView: View {
    @Binding var selectedTab: PanelTab
    var onQuit: () -> Void

    @Namespace private var pillNamespace

    static let width: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(PanelTab.allCases) { tab in
                SidebarItemView(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    namespace: pillNamespace
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                }
            }

            Spacer()

            Divider()
                .padding(.vertical, 4)

            Button(action: onQuit) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .frame(width: 18)
                    Text("Выход")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .frame(width: Self.width, alignment: .top)
    }
}

/// Своя вью (а не функция) ради @State — нужен для лёгкой hover-подсветки
/// невыбранных пунктов; выбранный получает «переезжающую» пилюлю через
/// matchedGeometryEffect с общим namespace от родителя.
private struct SidebarItemView: View {
    let tab: PanelTab
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(tab.title)
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.8))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.18))
                        .matchedGeometryEffect(id: "sidebarPill", in: namespace)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
