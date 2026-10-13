import Foundation
import Testing
@testable import Oasis

@Suite("Spaces", .serialized)
@MainActor struct SpacesTests {
    private func storageURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OasisSpacesTests-\(UUID())/Library.json")
    }

    private func webpage(_ session: BrowserSession, path: String) -> BrowserTab {
        let tab = session.newTab()
        tab.url = URL(string: "https://example.com/\(path)")!
        tab.isBlankPage = false
        tab.title = path
        return tab
    }

    @Test func switchingSpacesPreservesLiveTabsAndRemembersSelection() {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let session = BrowserSession(library: BrowserLibrary(storageURL: file))
        let garden = session.currentSpaceID
        let cloud = session.spaces[1].id
        let first = webpage(session, path: "one")
        let second = webpage(session, path: "two")
        let view = second.webView
        session.selectSpace(cloud)
        #expect(session.currentTabs.isEmpty && session.selectedTab == nil)
        let third = webpage(session, path: "three")
        session.selectSpace(garden)
        #expect(session.currentTabs.map(\.id) == [first.id, second.id])
        #expect(session.selectedTab === second)
        #expect(session.selectedTab?.webView === view)
        session.selectSpace(cloud)
        #expect(session.selectedTab === third)
        #expect(session.tabs.count == 3)
    }

    @Test func clearOnlyClosesCurrentUnpinnedTabsAndCanReopenThem() {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let session = BrowserSession(library: BrowserLibrary(storageURL: file))
        let garden = session.currentSpaceID
        let cloud = session.spaces[1].id
        let pinned = webpage(session, path: "pinned")
        session.togglePin(pinned)
        _ = webpage(session, path: "one")
        let last = webpage(session, path: "two")
        session.selectSpace(cloud)
        let other = webpage(session, path: "cloud")
        session.selectSpace(garden)
        session.clearCurrentSpace()
        #expect(session.currentTabs.map(\.id) == [pinned.id])
        #expect(session.selectedTab === pinned)
        #expect(session.tabs.contains { $0 === other })
        #expect(session.closedTabs.count == 2)
        session.selectSpace(cloud)
        session.reopenClosedTab()
        #expect(session.currentSpaceID == garden)
        #expect(session.selectedTab?.url == last.url)
        #expect(session.selectedTab?.spaceID == garden)
    }

    @Test func draggingToAnotherSpaceKeepsTheSameWebView() {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let session = BrowserSession(library: BrowserLibrary(storageURL: file))
        let garden = session.currentSpaceID
        let cloud = session.spaces[1].id
        let remaining = webpage(session, path: "remaining")
        let moved = webpage(session, path: "moved")
        let view = moved.webView
        session.togglePin(moved)
        #expect(session.moveTabToSpace(moved.id, to: cloud))
        #expect(session.currentSpaceID == cloud && session.selectedTab === moved)
        #expect(session.selectedTab?.webView === view)
        #expect(moved.isPinned)
        session.selectSpace(garden)
        #expect(session.currentTabs.map(\.id) == [remaining.id])
        #expect(session.selectedTab === remaining)
        #expect(!session.moveTabToSpace(moved.id, to: UUID()))
        #expect(!session.moveTab(remaining.id, before: moved.id))
    }

    @Test func namesAndEmojiPersistAndRejectInvalidIcons() {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let session = BrowserSession(library: library)
        #expect(!session.addSpace(name: "", emoji: "🌙"))
        #expect(!session.addSpace(name: "Work", emoji: "X"))
        #expect(!session.addSpace(name: "Work", emoji: "🌙🔥"))
        #expect(session.addSpace(name: " Work ", emoji: "💼"))
        let id = session.currentSpaceID
        session.updateSpace(id, name: "Studio", emoji: "🎨")
        library.flush()
        let restored = BrowserLibrary(storageURL: file)
        #expect(restored.spaces.last?.name == "Studio")
        #expect(restored.spaces.last?.emoji == "🎨")
        #expect(restored.spaces.last?.id == id)
        #expect(BrowserSpace.isValidEmoji("☁️"))
        #expect(BrowserSpace.isValidEmoji("👩‍💻"))
        #expect(!BrowserSpace.isValidEmoji("9"))
    }

    @Test func deletingASpaceMovesItsTabsAcrossNormalWindows() {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let first = BrowserSession(library: library)
        let second = BrowserSession(library: library)
        first.activate(); second.activate()
        defer { first.shutdown(); second.shutdown() }
        let garden = first.spaces[0].id
        let cloud = first.spaces[1].id
        first.selectSpace(cloud); second.selectSpace(cloud)
        let one = webpage(first, path: "one")
        let two = webpage(second, path: "two")
        #expect(first.removeSpace(cloud))
        #expect(first.currentSpaceID == garden && second.currentSpaceID == garden)
        #expect(first.selectedTab === one && second.selectedTab === two)
        #expect(one.spaceID == garden && two.spaceID == garden)
        #expect(!first.removeSpace(garden))
        #expect(first.spaces.count == 1)
        #expect(first.closedTabs.isEmpty && second.closedTabs.isEmpty)
    }

    @Test func privateSpacesDoNotWriteDefinitionsOrTabs() {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let session = BrowserSession(library: library, isPrivate: true)
        let other = BrowserSession(library: library, isPrivate: true)
        #expect(session.addSpace(name: "Private", emoji: "🔒"))
        _ = webpage(session, path: "secret")
        session.clearCurrentSpace()
        library.flush()
        #expect(session.spaces.count == 3)
        #expect(other.spaces.count == 2 && library.spaces.count == 2)
        #expect(BrowserLibrary(storageURL: file).spaces.count == 2)
        #expect(library.data.windows.isEmpty)
        #expect(session.closedTabs.isEmpty)
    }

    @Test func snapshotsRestoreSpacesAndTheirSelections() {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let library = BrowserLibrary(storageURL: file)
        let session = BrowserSession(library: library)
        let garden = session.currentSpaceID
        _ = webpage(session, path: "one")
        let gardenSelected = webpage(session, path: "two")
        let cloud = session.spaces[1].id
        session.selectSpace(cloud)
        let cloudSelected = webpage(session, path: "three")
        let restored = BrowserSession(library: library)
        restored.activate(restored: session.snapshot)
        defer { restored.shutdown() }
        #expect(restored.currentSpaceID == cloud)
        #expect(restored.selectedTab?.url == cloudSelected.url)
        restored.selectSpace(garden)
        #expect(restored.selectedTab?.url == gardenSelected.url)
        #expect(restored.currentTabs.count == 2)
        restored.cycleTab(1)
        #expect(restored.selectedTab?.url?.lastPathComponent == "one")
    }

    @Test func oldEssentialsBecomeBookmarksAndOldTabsRemainAvailable() throws {
        let file = storageURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID()
        let legacy = Data("""
            {"history":[],"bookmarks":[],"essentials":[{"id":"\(id)","url":"https://example.com/saved","title":"Saved"}],"windows":{"old":{"tabs":[{"url":"https://example.com/open","isPinned":false,"essentialID":"\(id)"}],"selectedIndex":0}}}
            """.utf8)
        try legacy.write(to: file)
        let library = BrowserLibrary(storageURL: file)
        #expect(library.storageError == nil)
        #expect(library.data.essentials == nil)
        #expect(library.bookmarks.first?.title == "Saved")
        let saved = try #require(library.data.windows["old"])
        let session = BrowserSession(library: library)
        session.activate(restored: saved)
        defer { session.shutdown() }
        #expect(session.currentSpace.name == "The Garden")
        #expect(session.currentTabs.count == 1)
        #expect(session.selectedTab?.url?.lastPathComponent == "open")
    }
}
