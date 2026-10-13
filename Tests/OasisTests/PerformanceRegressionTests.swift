import Foundation
import Observation
import Synchronization
import Testing
@testable import Oasis

@Suite("Performance regressions", .serialized)
@MainActor struct PerformanceRegressionTests {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OasisPerformance-\(UUID())/Library.json")
    }

    @Test func restoredBackgroundTabsDoNotCreateWebViewsUntilSelected() async throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let garden = library.spaces[0].id, cloud = library.spaces[1].id
        let tabs = (0..<40).map { index in
            SavedTab(url: URL(string: "data:text/html,<title>Saved-\(index)</title>"),
                     isPinned: index == 0, spaceID: index < 30 ? garden : cloud)
        }
        let session = BrowserSession(library: library)
        session.activate(restored: SavedWindow(tabs: tabs, selectedIndex: 0, selectedSpaceID: garden))
        defer { session.shutdown() }
        #expect(session.tabs.filter(\.hasWebView).count == 1)
        #expect(session.snapshot.tabs == tabs)
        let untouched = session.tabs[20]
        session.select(session.tabs[1].id)
        #expect(session.tabs.filter(\.hasWebView).count == 2)
        session.select(session.tabs[35].id)
        #expect(session.currentSpaceID == cloud)
        #expect(session.tabs.filter(\.hasWebView).count == 3)
        for _ in 0..<100 {
            if session.selectedTab?.webView.title == "Saved-35" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(session.selectedTab?.webView.title == "Saved-35")
        untouched.setSpoofMode(true)
        session.closeTab(untouched.id)
        #expect(!untouched.hasWebView)
        library.flush()
        #expect(BrowserLibrary(storageURL: file).data.windows[session.id.uuidString]?.tabs.count == 39)
    }

    @Test func backgroundStorageWritesOffMainAndFinalFlushWins() async throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let storage = LibraryStorage(url: file)
        var previous = LibraryData()
        previous.history = (0..<10_000).map { index in
            HistoryEntry(url: URL(string: "https://example.com/\(index)")!, title: "Saved visit \(index)")
        }
        let offMain: Bool = await withCheckedContinuation { continuation in
            storage.schedule(previous) { _ in continuation.resume(returning: !Thread.isMainThread) }
        }
        #expect(offMain)
        for _ in 0..<3 { storage.schedule(previous) { _ in } }
        var latest = LibraryData()
        latest.bookmarks = [Bookmark(url: URL(string: "https://example.com/latest")!, title: "Latest")]
        try storage.flush(latest)
        let result = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: file))
        #expect(result.history.isEmpty)
        #expect(result.bookmarks.first?.title == "Latest")
    }

    @Test func savingTabSelectionDoesNotInvalidateLibraryLists() {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let session = BrowserSession(library: library)
        session.activate()
        defer { session.shutdown() }
        let changes = Mutex(0)
        withObservationTracking {
            _ = library.history
            _ = library.bookmarks
            _ = library.spaces
        } onChange: { changes.withLock { $0 += 1 } }
        session.newTab()
        session.newTab()
        session.select(session.tabs[0].id)
        #expect(changes.withLock { $0 } == 0)
        library.addBookmark(url: URL(string: "https://example.com")!, title: "Example")
        #expect(changes.withLock { $0 } == 1)
    }
}
