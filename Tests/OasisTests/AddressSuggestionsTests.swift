import Foundation
import Testing
@testable import Oasis

@Suite("Address suggestions")
struct AddressSuggestionsTests {
    @Test func rankingAndDeduplicationPreserveBookmarkAndRecentHistoryOrder() {
        let url = URL(string: "https://swift.example.com")!
        let bookmarks = [
            Bookmark(url: URL(string: "https://other.example.com")!, title: "Swift guide"),
            Bookmark(url: url, title: "Bookmarked swift site")
        ]
        let history = [
            HistoryEntry(url: url, title: "History duplicate"),
            HistoryEntry(url: URL(string: "https://swift-lang.example.com")!, title: "Swift language"),
            HistoryEntry(url: URL(string: "https://example.com/a-swift-page")!, title: "Reference")
        ]
        let result = AddressSuggestions.matches("swift", bookmarks: bookmarks, history: history)
        #expect(result.map(\.title) == ["Bookmarked swift site", "Swift language", "Swift guide", "Reference"])
        #expect(result[0].symbol == "bookmark")
    }

    @Test func limitsResultsAndExcludesNonWebAndOldHistory() {
        let history = (0..<1001).map { index in
            HistoryEntry(url: URL(string: "https://example.com/\(index)")!, title: "Visit-\(index)")
        }
        #expect(AddressSuggestions.matches("visit", bookmarks: [], history: history).count == 6)
        #expect(AddressSuggestions.matches("Visit-1000", bookmarks: [], history: history).isEmpty)
        let local = Bookmark(url: URL(fileURLWithPath: "/tmp/private.txt"), title: "Local")
        #expect(AddressSuggestions.matches("Local", bookmarks: [local], history: []).isEmpty)
        #expect(AddressSuggestions.matches("   ", bookmarks: [], history: history).isEmpty)
        #expect(AddressSuggestions.matches("youtube", bookmarks: [], history: []).first?.url.host == "youtube.com")
    }
}
