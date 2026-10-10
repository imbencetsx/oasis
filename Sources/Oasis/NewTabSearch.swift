import SwiftUI

/// A window-wide search surface. A tab is created only after the user confirms a destination.
struct NewTabSearch: View {
  @Bindable var session: BrowserSession
  @State private var query = ""
  @State private var selection: String?
  @State private var hasEntered = false
  @State private var typingGlow = 0.0
  @FocusState private var isFocused: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var suggestions: [AddressSuggestion] {
    AddressSuggestions.matches(
      query, bookmarks: session.library.bookmarks,
      history: session.isPrivate ? [] : session.library.history)
  }
  private var effectiveSuggestionID: String? { selection ?? suggestions.first?.id }
  private var glow: AngularGradient {
    AngularGradient(colors: [.red, .orange, .pink, .purple, .red], center: .center)
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Button {
          dismiss()
        } label: {
          Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Dismiss search")

        GlassEffectContainer(spacing: 12) {
          VStack(spacing: 12) {
            HStack(spacing: 12) {
              TextField("Search or enter a website", text: $query)
                .textFieldStyle(.plain).font(.system(size: 23, weight: .regular))
                .frame(maxWidth: .infinity, minHeight: 76)
                .focused($isFocused).tint(Color.oasisAccent)
                .accessibilityLabel("Search or enter a website")
                .onSubmit { submit() }
                .onKeyPress(.downArrow) {
                  moveSelection(1)
                  return .handled
                }
                .onKeyPress(.upArrow) {
                  moveSelection(-1)
                  return .handled
                }
                .onExitCommand { dismiss() }
              Button {
                submit()
              } label: {
                Image(systemName: "arrow.up")
                  .font(.system(size: 18, weight: .medium))
                  .frame(width: 38, height: 38)
                  .background(Color.primary.opacity(0.08), in: Circle())
                  .contentShape(Circle())
              }.buttonStyle(.plain).disabled(
                query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              )
              .help("Open website or search").accessibilityLabel("Open website or search")
            }
            .padding(.leading, 28).padding(.trailing, 19)
            .background(
              reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear, in: Capsule()
            )
            .glassEffect(
              reduceTransparency ? .identity : .regular,
              in: .capsule
            )
            .overlay {
              if !reduceTransparency {
                Capsule().strokeBorder(glow, lineWidth: 2).blur(radius: 7)
                  .opacity(0.15 + typingGlow * 0.09)
                  .allowsHitTesting(false).accessibilityHidden(true)
                Capsule().strokeBorder(glow, lineWidth: 0.8).opacity(0.18)
                  .allowsHitTesting(false).accessibilityHidden(true)
              }
            }
            .shadow(color: .black.opacity(0.10), radius: 24, y: 8)
          }
        }
        .frame(width: min(640, max(240, geometry.size.width - 64)))
        .overlay(alignment: .top) {
          if !suggestions.isEmpty {
            AddressSuggestionList(
              suggestions: suggestions, selection: effectiveSuggestionID,
              onSelect: { open($0) },
              maximumHeight: max(120, min(330, geometry.size.height * 0.66 - 58))
            )
            .padding(.top, 88)
            .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: suggestions.map(\.id))
        .opacity(hasEntered ? 1 : 0)
        .scaleEffect(reduceMotion || hasEntered ? 1 : 1.10)
        .offset(y: reduceMotion || hasEntered ? 0 : 24)
        .blur(radius: reduceMotion || hasEntered ? 0 : 4)
        .animation(
          reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.42, bounce: 0.04),
          value: hasEntered
        )
        .offset(y: -min(120, geometry.size.height * 0.16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .defaultFocus($isFocused, true)
    .task {
      isFocused = true
      hasEntered = true
    }
    .onChange(of: query) {
      selection = nil
      if !reduceMotion {
        withAnimation(.easeOut(duration: 0.12)) { typingGlow = 1 }
      }
    }
    .task(id: query) {
      guard !reduceMotion else { return }
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      withAnimation(.easeOut(duration: 0.3)) { typingGlow = 0 }
    }
  }

  private func moveSelection(_ offset: Int) {
    selection = AddressSuggestions.moveSelection(effectiveSuggestionID, in: suggestions, by: offset)
  }
  private func submit() {
    if let suggestion = suggestions.first(where: { $0.id == effectiveSuggestionID }) {
      open(suggestion)
    } else if let url = AddressResolver.resolve(query, engine: session.library.searchEngine) {
      session.newTab(url: url)
      dismiss()
    }
  }
  private func open(_ suggestion: AddressSuggestion) {
    session.newTab(url: suggestion.url)
    dismiss()
  }
  private func dismiss() {
    isFocused = false
    session.showsNewTabSearch = false
  }
}
