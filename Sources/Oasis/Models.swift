import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    var visitedAt = Date()
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var title: String
    var isFavorite = true
    var isReadingList = false
    var isRead = false
    var createdAt = Date()
}

struct SavedTab: Codable, Hashable {
    var url: URL?
    var isPinned: Bool
}

struct SavedWindow: Codable, Hashable {
    var tabs: [SavedTab]
    var selectedIndex: Int
}

struct LibraryData: Codable {
    var history: [HistoryEntry] = []
    var bookmarks: [Bookmark] = []
    var windows: [String: SavedWindow] = [:]
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
