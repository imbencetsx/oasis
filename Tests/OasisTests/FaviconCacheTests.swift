import AppKit
import Foundation
import Testing
@testable import Oasis

@Suite("Favicon cache", .serialized)
@MainActor struct FaviconCacheTests {
    private func makeLibrary() -> BrowserLibrary {
        BrowserLibrary(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("favicons-\(UUID().uuidString).json"))
    }

    @Test func storesAndFindsByHost() {
        let library = makeLibrary()
        let page = URL(string: "https://example.com/some/page")!
        #expect(library.favicon(for: page) == nil)
        library.storeFavicon(NSImage(), for: page)
        #expect(library.favicon(for: page) != nil)
        // Same host, different page shares the icon.
        #expect(library.favicon(for: URL(string: "https://example.com/other")!) != nil)
        // Different host has none.
        #expect(library.favicon(for: URL(string: "https://example.org/")!) == nil)
    }

    @Test func hostMatchingIsCaseInsensitive() {
        let library = makeLibrary()
        library.storeFavicon(NSImage(), for: URL(string: "https://Example.COM/")!)
        #expect(library.favicon(for: URL(string: "https://example.com/x")!) != nil)
    }

    @Test func firstIconPerHostWins() {
        let library = makeLibrary()
        let url = URL(string: "https://example.com/")!
        let first = NSImage()
        library.storeFavicon(first, for: url)
        library.storeFavicon(NSImage(), for: url)
        #expect(library.favicon(for: url) === first)
    }

    @Test func ignoresNonWebURLs() {
        let library = makeLibrary()
        let file = URL(string: "file:///tmp/icon.png")!
        library.storeFavicon(NSImage(), for: file)
        library.fetchFavicon(for: file)
        #expect(library.favicon(for: file) == nil)
        #expect(BrowserLibrary.faviconHost(for: file) == nil)
        #expect(BrowserLibrary.faviconHost(for: URL(string: "about:blank")!) == nil)
    }

    @Test func capsCacheSize() {
        let library = makeLibrary()
        for i in 0..<600 {
            library.storeFavicon(NSImage(), for: URL(string: "https://host\(i).example/")!)
        }
        #expect(library.favicons.count <= 500)
    }
}
