import SwiftUI

struct TabSidebar: View {
  static let topInset: CGFloat = 44
  @Bindable var session: BrowserSession
  @State private var targetedSpaceID: UUID?
  @State private var editingSpace: BrowserSpace?
  @State private var showsSpaceEditor = false
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

  var body: some View {
    let unpinnedTabs = session.unpinnedTabs
    return VStack(alignment: .leading, spacing: 0) {
      currentSpaceHeader
      ScrollView {
        LazyVStack(spacing: 3) {
          ForEach(session.pinnedTabs) { tab in tabRow(tab) }
          HStack(spacing: 8) {
            Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
            Button { session.clearCurrentSpace() } label: {
              Label("Clear", systemImage: "arrow.down")
                .font(.system(size: 10))
                .padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(OasisButtonStyle())
            .foregroundStyle(.secondary)
            .disabled(unpinnedTabs.isEmpty)
            .help("Close unpinned tabs in \(session.currentSpace.name)")
          }.padding(.horizontal, 4).padding(.vertical, 1)
          Button { session.openNewTabSearch() } label: {
            Label("New Tab", systemImage: "plus")
              .font(.system(size: 12))
              .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
              .padding(.leading, 11).contentShape(Rectangle())
          }.buttonStyle(OasisButtonStyle()).foregroundStyle(.secondary)
          ForEach(unpinnedTabs) { tab in tabRow(tab) }
        }.padding(.horizontal, 10).padding(.bottom, 12)
      }.scrollIndicators(.hidden)
      spaceSwitcher
    }
    .padding(.top, Self.topInset)
    .frame(maxHeight: .infinity)
    .sheet(isPresented: $showsSpaceEditor) {
      SpaceEditor(space: editingSpace) { name, emoji in
        if let space = editingSpace { session.updateSpace(space.id, name: name, emoji: emoji) }
        else { session.addSpace(name: name, emoji: emoji) }
      }
    }
  }

  private var currentSpaceHeader: some View {
    HStack(spacing: 8) {
      Text(session.currentSpace.emoji).font(.system(size: 17)).accessibilityHidden(true)
      Text(session.currentSpace.name).font(.system(size: 12, weight: .bold)).lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(height: 24).padding(.horizontal, 16)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Edit Space…") { edit(session.currentSpace) }
      Button("New Space…") { edit(nil) }
      Divider()
      Button("Delete Space", role: .destructive) { session.removeSpace(session.currentSpaceID) }
        .disabled(session.spaces.count == 1)
    }
    .help(session.currentSpace.name)
  }

  private var spaceSwitcher: some View {
    HStack(spacing: 4) {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          ForEach(session.spaces) { space in
            Button { session.selectSpace(space.id) } label: {
              ZStack(alignment: .bottomTrailing) {
                Text(space.emoji).font(.system(size: 15)).frame(width: 32, height: 32)
                if differentiateWithoutColor && space.id == session.currentSpaceID {
                  Image(systemName: "checkmark").font(.system(size: 7, weight: .semibold)).padding(2)
                }
              }.contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(OasisButtonStyle())
            .background(Color.primary.opacity(space.id == session.currentSpaceID || targetedSpaceID == space.id ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(targetedSpaceID == space.id ? 0.3 : 0)))
            .help(space.name).accessibilityLabel("\(space.name) space")
            .accessibilityAddTraits(space.id == session.currentSpaceID ? [.isSelected] : [])
            .dropDestination(for: String.self) { values, _ in
              guard let value = values.first, let id = UUID(uuidString: value) else { return false }
              return session.moveTabToSpace(id, to: space.id)
            } isTargeted: { targeted in
              if targeted { targetedSpaceID = space.id }
              else if targetedSpaceID == space.id { targetedSpaceID = nil }
            }
            .contextMenu {
              Button("Edit Space…") { edit(space) }
              Button("Delete Space", role: .destructive) { session.removeSpace(space.id) }
                .disabled(session.spaces.count == 1)
            }
          }
        }.padding(.horizontal, 2)
      }.scrollIndicators(.hidden).frame(height: 36)
      Button { edit(nil) } label: {
        Label("New Space", systemImage: "plus").labelStyle(.iconOnly)
          .font(.system(size: 16)).frame(width: 32, height: 32).contentShape(Rectangle())
      }.buttonStyle(OasisButtonStyle()).help("New Space")
    }.padding(.horizontal, 10).padding(.bottom, 10)
  }

  private func tabRow(_ tab: BrowserTab) -> some View {
    SidebarTabRow(tab: tab, isSelected: session.selectedID == tab.id,
                  onSelect: { session.select(tab.id) }, onClose: { session.closeTab(tab.id) })
      .draggable(tab.id.uuidString)
      .dropDestination(for: String.self) { values, _ in
        guard let value = values.first, let id = UUID(uuidString: value) else { return false }
        return session.moveTab(id, before: tab.id)
      }
      .contextMenu {
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { session.togglePin(tab) }
        Menu("Move to Space") {
          ForEach(session.spaces) { space in
            Button("\(space.emoji) \(space.name)") { session.moveTabToSpace(tab.id, to: space.id) }
              .disabled(tab.spaceID == space.id)
          }
        }
        Button("Duplicate Tab") { session.newTab(url: tab.isBlankPage ? nil : tab.url) }
        Button("Reload Tab") { tab.reload() }.disabled(tab.isBlankPage)
        Divider()
        Button("Close Tab") { session.closeTab(tab.id) }
        Button("Close Other Tabs") {
          session.closeTabs(Set(session.currentTabs.filter { $0.id != tab.id && !$0.isPinned }.map(\.id)))
        }
      }
  }

  private func edit(_ space: BrowserSpace?) {
    editingSpace = space
    showsSpaceEditor = true
  }
}

private struct SpaceEditor: View {
  let space: BrowserSpace?
  let onSave: (String, String) -> Void
  @State private var name = ""
  @State private var emoji = "🌱"
  @FocusState private var nameFocused: Bool
  @Environment(\.dismiss) private var dismiss
  private var valid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && BrowserSpace.isValidEmoji(emoji)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(space == nil ? "New Space" : "Edit Space").font(.headline)
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Emoji").font(.caption).foregroundStyle(.secondary)
          TextField("Emoji", text: $emoji).multilineTextAlignment(.center).frame(width: 48)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("Name").font(.caption).foregroundStyle(.secondary)
          TextField("Space name", text: $name).focused($nameFocused)
        }
      }.textFieldStyle(.roundedBorder)
      Text("Choose one emoji. Use ⌃⌘Space to open the emoji picker.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(space == nil ? "Create Space" : "Save") {
          onSave(name, emoji)
          dismiss()
        }.keyboardShortcut(.defaultAction).disabled(!valid)
      }
    }.padding(24).frame(width: 360)
      .onAppear {
        name = space?.name ?? ""
        emoji = space?.emoji ?? "🌱"
        nameFocused = true
      }
  }
}

/// The caller owns selection; hover is transient presentation state local to the row.
struct SidebarTabRow: View {
  let tab: BrowserTab
  let isSelected: Bool
  let onSelect: () -> Void
  let onClose: () -> Void
  @State private var hovering = false
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  var body: some View {
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
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
      }.buttonStyle(OasisButtonStyle(pressScale: 0.985, hoverScale: 1.005, tilt: 0))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      Button(action: onClose) {
        Label("Close Tab", systemImage: "xmark")
          .labelStyle(.iconOnly).font(.system(size: 9, weight: .semibold))
          .frame(width: 28, height: 32).contentShape(Rectangle())
      }.buttonStyle(OasisButtonStyle()).padding(.trailing, 3)
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
