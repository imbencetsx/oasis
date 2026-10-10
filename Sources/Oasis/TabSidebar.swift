import SwiftUI

struct TabSidebar: View {
  @Bindable var session: BrowserSession
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView {
        LazyVStack(spacing: 3) {
          ForEach(session.tabs) { tab in
            SidebarTabRow(tab: tab, selection: $session.selectedID) { session.closeTab(tab.id) }
              .draggable(tab.id.uuidString)
              .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let id = UUID(uuidString: value) else {
                  return false
                }
                session.moveTab(id, before: tab.id)
                return true
              }
              .contextMenu {
                Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePin(tab) }
                Button("Duplicate Tab") { session.newTab(url: tab.isBlankPage ? nil : tab.url) }
                Button("Reload Tab") { tab.reload() }.disabled(tab.isBlankPage)
                Divider()
                Button("Close Tab") { session.closeTab(tab.id) }
                Button("Close Other Tabs") {
                  for other in session.tabs where other.id != tab.id && !other.isPinned {
                    session.closeTab(other.id)
                  }
                }
              }
          }
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }.scrollIndicators(.hidden)
    }
    .padding(.top, 64)
    .frame(maxHeight: .infinity)
    .background {
      if let color = session.selectedTab?.sidebarTint {
        Color(nsColor: color).opacity(0.35)
      } else {
        Rectangle().fill(.thinMaterial.opacity(0.28))
      }
    }
  }
}

/// The caller owns selection; hover is transient presentation state local to the row.
struct SidebarTabRow: View {
  let tab: BrowserTab
  @Binding var selection: UUID?
  let onClose: () -> Void
  @State private var hovering = false
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  private var isSelected: Bool { selection == tab.id }
  init(tab: BrowserTab, selection: Binding<UUID?>, onClose: @escaping () -> Void) {
    self.tab = tab
    _selection = selection
    self.onClose = onClose
  }
  var body: some View {
    ZStack(alignment: .trailing) {
      Button {
        selection = tab.id
      } label: {
        HStack(spacing: 9) {
          if tab.isLoading {
            ProgressView().controlSize(.mini).frame(width: 16)
          } else if let favicon = tab.favicon {
            Image(nsImage: favicon).resizable().scaledToFit().frame(width: 16, height: 16)
              .accessibilityHidden(true)
          } else {
            Image(systemName: tab.isBlankPage ? "plus" : "doc")
              .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
          }
          Text(tab.title).font(.system(size: 12, weight: isSelected ? .medium : .regular))
            .lineLimit(1)
          Spacer(minLength: 0)
          if tab.isPinned {
            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
          }
          if isSelected && differentiateWithoutColor {
            Image(systemName: "checkmark").font(.caption2)
          }
        }
        .padding(.leading, 11).padding(.trailing, 34)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 9))
      }.buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      Button(action: onClose) {
        Label("Close Tab", systemImage: "xmark")
          .labelStyle(.iconOnly).font(.system(size: 9, weight: .semibold))
          .frame(width: 28, height: 32).contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.trailing, 3)
        .opacity(hovering ? 0.9 : 0)
        .allowsHitTesting(hovering)
        .help("Close \(tab.title)")
    }
    .background(
      isSelected
        ? Color.primary.opacity(0.11) : hovering ? Color.primary.opacity(0.045) : .clear,
      in: RoundedRectangle(cornerRadius: 9)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9).strokeBorder(
        isSelected ? Color.primary.opacity(0.055) : .clear
      )
      .allowsHitTesting(false)
    )
    .onHover { hovering = $0 }
    .help(tab.url?.absoluteString ?? "about:blank")
    .accessibilityElement(children: .contain)
  }
}
