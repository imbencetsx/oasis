import Foundation

struct HistoryEntry: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    var visitedAt = Date()
}

struct Bookmark: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    var isFavorite = true
    var isReadingList = false
    var isRead = false
    var createdAt = Date()
}

struct SavedTab: Codable, Sendable, Hashable {
    var url: URL?
    var isPinned: Bool
    var spaceID: UUID? = nil
}

// Decode previous Essentials once so their saved links can become bookmarks.
struct LegacyEssentialLink: Codable, Sendable {
    var url: URL
    var title: String
}

struct SavedWindow: Codable, Sendable, Hashable {
    var tabs: [SavedTab]
    var selectedIndex: Int
    var selectedSpaceID: UUID? = nil
    var selectedIndicesBySpace: [String: Int]? = nil
}

struct BrowserSpace: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String

    static let defaults = [
        BrowserSpace(id: UUID(uuidString: "24B46DB5-AAD0-4D1B-BDB8-1C3802A00001")!, name: "The Garden", emoji: "🌱"),
        BrowserSpace(id: UUID(uuidString: "24B46DB5-AAD0-4D1B-BDB8-1C3802A00002")!, name: "Cloud", emoji: "☁️")
    ]

    static func isValidEmoji(_ value: String) -> Bool {
        value.count == 1 && value.unicodeScalars.contains { $0.properties.isEmoji && $0.value > 0x7F }
    }
}

struct LibraryData: Codable, Sendable {
    var history: [HistoryEntry] = []
    var bookmarks: [Bookmark] = []
    var windows: [String: SavedWindow] = [:]
    // Optional so libraries from earlier versions continue to decode.
    var essentials: [LegacyEssentialLink]? = nil
    var spaces: [BrowserSpace]? = nil
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo = "DuckDuckGo", google = "Google", bing = "Bing", brave = "Brave"
    var id: String { rawValue }
    func searchURL(for query: String) -> URL {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .google: base = "https://www.google.com/search"
        case .bing: base = "https://www.bing.com/search"
        case .brave: base = "https://search.brave.com/search"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}

enum AddressResolver {
    static func resolve(_ text: String, engine: SearchEngine) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // Only navigation schemes belong in the address bar; scripts are never executed here.
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            if ["http", "https"].contains(scheme), url.host == nil { return nil }
            return url
        }
        if !value.contains(where: { $0.isWhitespace }) {
            let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
            if host == "localhost" || host.hasPrefix("localhost:") || host.contains(".") || host.hasPrefix("[") {
                let local = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") || host.hasPrefix("[::1]")
                if let url = URL(string: "\(local ? "http" : "https")://\(value)"), url.host != nil { return url }
            }
        }
        return engine.searchURL(for: value)
    }
}

extension URL {
    var displayHost: String { (host ?? absoluteString).replacingOccurrences(of: "www.", with: "") }
    var isWebURL: Bool { ["http", "https"].contains(scheme?.lowercased() ?? "") }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case bookmarks = "Bookmarks", history = "History", readingList = "Reading List"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .bookmarks: "book.closed"
        case .history: "clock"
        case .readingList: "eyeglasses"
        }
    }
}
