import Testing
import Foundation
import WebKit
@testable import Oasis

@Suite("Address resolution")
struct AddressTests {
    @Test func whitespaceAndEmptyInput() {
        #expect(AddressResolver.resolve("  \n ", engine: .duckDuckGo) == nil)
        #expect(AddressResolver.resolve(" https://example.com/a ", engine: .google)?.absoluteString == "https://example.com/a")
    }
    @Test func domainsAndLocalDevelopment() {
        #expect(AddressResolver.resolve("example.com/path?q=hello", engine: .duckDuckGo)?.absoluteString == "https://example.com/path?q=hello")
        #expect(AddressResolver.resolve("localhost:8080/page", engine: .google)?.absoluteString == "http://localhost:8080/page")
        #expect(AddressResolver.resolve("127.0.0.1:8080", engine: .google)?.scheme == "http")
        #expect(AddressResolver.resolve("[::1]:8080", engine: .google)?.scheme == "http")
    }
    @Test(arguments: SearchEngine.allCases) func queryEscaping(engine: SearchEngine) {
        let query = "swift & swiftui #1 + cafés"
        let url = AddressResolver.resolve(query, engine: engine)!
        #expect(url.scheme == "https")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == query)
    }
    @Test func neverExecuteJavascriptFromAddressBar() {
        let url = AddressResolver.resolve("javascript:alert(1)", engine: .duckDuckGo)
        #expect(url?.scheme == "https")
        #expect(url?.host == "duckduckgo.com")
    }
}

@Suite("Library persistence", .serialized)
@MainActor struct LibraryTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OasisTests-\(UUID())").appendingPathComponent("Library.json")
    }
    @Test func bookmarksHistoryAndRestorationRoundTrip() throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let url = URL(string: "https://example.com/article")!
        library.recordVisit(url: url, title: "Article")
        library.recordVisit(url: url, title: "Updated article")
        #expect(library.history.count == 1)
        library.addBookmark(url: url, title: "Article")
        library.addBookmark(url: url, title: "Duplicate")
        library.addBookmark(url: url, title: "For later", readingList: true)
        #expect(library.bookmarks.count == 1)
        #expect(library.readingList.count == 1)
        library.flush()
        let restored = BrowserLibrary(storageURL: file)
        #expect(restored.history.first?.title == "Updated article")
        #expect(restored.favorites.count == 1)
        #expect(restored.readingList.count == 1)
        restored.clearHistory()
        restored.flush()
        #expect(BrowserLibrary(storageURL: file).history.isEmpty)
        #expect(BrowserLibrary(storageURL: file).bookmarks.count == 1)
    }
    @Test func unreadableLibraryIsNeverOverwritten() throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("damaged original data".utf8)
        try original.write(to: file)
        let library = BrowserLibrary(storageURL: file)
        #expect(library.storageError != nil)
        library.addBookmark(url: URL(string: "https://example.com")!, title: "Example")
        library.flush()
        #expect(try Data(contentsOf: file) == original)
    }
    @Test func privateSessionNeverPersistsTabs() throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let session = BrowserSession(library: library, isPrivate: true)
        session.activate()
        let first = session.newTab()
        #expect(first.webView.configuration.websiteDataStore.isPersistent == false)
        let second = session.newTab()
        #expect(second.webView.configuration.websiteDataStore === session.tabs[0].webView.configuration.websiteDataStore)
        library.flush()
        #expect(library.data.windows.isEmpty)
        #expect(BrowserLibrary(storageURL: file).data.windows.isEmpty)
        #expect(session.closedTabs.isEmpty)
        session.shutdown()
    }
    @Test func privateWindowsHaveDifferentStores() {
        let library = BrowserLibrary(storageURL: temporaryURL())
        let a = BrowserSession(library: library, isPrivate: true)
        let b = BrowserSession(library: library, isPrivate: true)
        let first = a.newTab()
        let second = b.newTab()
        #expect(first.webView.configuration.websiteDataStore !== second.webView.configuration.websiteDataStore)
    }
    @Test func tabSelectionSurvivesClosingAndPinning() {
        let library = BrowserLibrary(storageURL: temporaryURL())
        let session = BrowserSession(library: library)
        let first = session.newTab()
        let second = session.newTab()
        session.togglePin(second)
        #expect(session.tabs.first?.id == second.id)
        session.closeTab(second.id)
        #expect(session.selectedID == first.id)
        session.closeTab(first.id)
        #expect(session.tabs.isEmpty)
        #expect(session.selectedTab == nil)
    }
    @Test func normalSessionSnapshotRestoresSelectionAndPin() throws {
        let file = temporaryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let session = BrowserSession(library: library)
        session.activate()
        session.newTab()
        let tab = session.newTab()
        session.togglePin(tab)
        library.flush()
        let saved = try #require(BrowserLibrary(storageURL: file).data.windows.values.first)
        #expect(saved.tabs.count == 2)
        #expect(saved.tabs[0].isPinned)
        #expect(saved.selectedIndex == 0)
        session.shutdown()
    }
}

@Suite("Original website rendering", .serialized)
@MainActor struct WebsiteRenderingTests {
    @Test func preservesWebsiteCSS() async throws {
        let tab = BrowserTab(isPrivate: true)
        defer { tab.close() }
        #expect(tab.webView.configuration.userContentController.userScripts.isEmpty)
        tab.webView.loadHTMLString("""
            <!doctype html><html><head><title>Original CSS</title></head>
            <body style="background: rgb(255, 0, 0); color: rgb(0, 0, 0)">Original website</body></html>
            """, baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if tab.webView.title == "Original CSS" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(tab.webView.title == "Original CSS")
        let background = try await tab.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        let foreground = try await tab.webView.evaluateJavaScript("getComputedStyle(document.body).color") as? String
        #expect(background == "rgb(255, 0, 0)")
        #expect(foreground == "rgb(0, 0, 0)")
    }
}
