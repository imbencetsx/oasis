import SwiftUI

struct AddressSuggestion: Identifiable {
  let url: URL
  let title: String
  let symbol: String
  var id: String { url.absoluteString }
}

/// Local completion candidates. Query text never leaves the app until navigation is confirmed.
enum AddressSuggestions {
  static func matches(_ query: String, bookmarks: [Bookmark], history: [HistoryEntry])
    -> [AddressSuggestion]
  {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return [] }
    let hostQuery = needle.replacingOccurrences(of: "https://", with: "")
      .replacingOccurrences(of: "http://", with: "")
      .replacingOccurrences(of: "www.", with: "")
    let commonSites = [
      ("YouTube", "youtube.com"), ("GitHub", "github.com"), ("Wikipedia", "wikipedia.org"),
      ("Google", "google.com"), ("Reddit", "reddit.com"), ("Apple", "apple.com"),
      ("Instagram", "instagram.com"), ("Amazon", "amazon.com"), ("DuckDuckGo", "duckduckgo.com"),
      ("Netflix", "netflix.com"), ("ChatGPT", "chatgpt.com"),
      ("Stack Overflow", "stackoverflow.com"),
    ]
    let candidates =
      bookmarks.map { AddressSuggestion(url: $0.url, title: $0.title, symbol: "bookmark") }
      + history.prefix(1000).map {
        AddressSuggestion(url: $0.url, title: $0.title, symbol: "clock")
      }
      + commonSites.compactMap { title, host -> AddressSuggestion? in
        guard let url = URL(string: "https://\(host)/") else { return nil }
        return AddressSuggestion(url: url, title: title, symbol: "globe")
      }
    var seen = Set<String>()
    return candidates.enumerated().compactMap {
      index, candidate -> (AddressSuggestion, Int, Int)? in
      guard candidate.url.isWebURL else { return nil }
      let host = candidate.url.displayHost.lowercased()
      let title = candidate.title.lowercased()
      let address = candidate.url.absoluteString.lowercased()
      let score: Int
      if host.hasPrefix(hostQuery) {
        score = 0
      } else if title.hasPrefix(needle) {
        score = 1
      } else if host.contains(hostQuery) || title.contains(needle) || address.contains(needle) {
        score = 2
      } else {
        return nil
      }
      guard seen.insert(candidate.id).inserted else { return nil }
      return (candidate, score, index)
    }.sorted { a, b in a.1 == b.1 ? a.2 < b.2 : a.1 < b.1 }
      .prefix(6).map { $0.0 }
  }

  static func moveSelection(
    _ selection: String?, in suggestions: [AddressSuggestion], by offset: Int
  ) -> String? {
    guard !suggestions.isEmpty else { return nil }
    guard let index = suggestions.firstIndex(where: { $0.id == selection }) else {
      return offset > 0 ? suggestions.first?.id : suggestions.last?.id
    }
    let next = index + offset
    // Wrap the highlighted result while preserving the exact text being edited.
    return suggestions[(next + suggestions.count) % suggestions.count].id
  }
}

struct AddressSuggestionList: View {
  let suggestions: [AddressSuggestion]
  let selection: String?
  let onSelect: (AddressSuggestion) -> Void
  var maximumHeight: CGFloat = 330
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 3) {
          ForEach(suggestions) { suggestion in
            Button {
              onSelect(suggestion)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: suggestion.symbol)
                  .font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                  Text(suggestion.title.isEmpty ? suggestion.url.displayHost : suggestion.title)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                  Text(suggestion.url.absoluteString).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if selection == suggestion.id {
                  Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }
              .padding(.horizontal, 14).padding(.vertical, 11)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                selection == suggestion.id ? Color.primary.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 14)
              )
              .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(suggestion.title), \(suggestion.url.displayHost)")
            .accessibilityHint("Open this website")
            .accessibilityAddTraits(selection == suggestion.id ? [.isSelected] : [])
            .transition(.opacity)
            .id(suggestion.id)
          }
        }.padding(7)
      }
      .scrollIndicators(.hidden)
      .onChange(of: selection) { _, id in
        if let id {
          withAnimation(reduceMotion ? nil : .smooth(duration: 0.16)) {
            proxy.scrollTo(id, anchor: .center)
          }
        }
      }
    }
    .frame(height: min(CGFloat(suggestions.count) * 58 + 14, maximumHeight))
    .clipShape(RoundedRectangle(cornerRadius: 21))
    .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: suggestions.map(\.id))
    .background(
      reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear,
      in: RoundedRectangle(cornerRadius: 21)
    )
    .glassEffect(reduceTransparency ? .identity : .regular, in: .rect(cornerRadius: 21))
  }
}
