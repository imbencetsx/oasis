import SwiftUI
import WebKit

@MainActor @Observable
final class BrowserLibrary {
    static let shared = BrowserLibrary()
    private var historyEntries: [HistoryEntry] = []
    private var bookmarkEntries: [Bookmark] = []
    private var spaceRecords: [BrowserSpace]?
    @ObservationIgnored private var windows: [String: SavedWindow] = [:]
    var data: LibraryData {
        LibraryData(history: historyEntries, bookmarks: bookmarkEntries, windows: windows, spaces: spaceRecords)
    }
    var storageError: String?
    var isClearingWebsiteData = false
    var spoofModeEnabled = false {
        didSet {
            guard spoofModeEnabled != oldValue else { return }
            if !spoofModeEnabled { ClipboardTyping.shared.stop() }
            UserDefaults.standard.set(spoofModeEnabled, forKey: "spoofMode")
            for session in sessions.values {
                for tab in session.tabs { tab.setSpoofMode(spoofModeEnabled) }
            }
        }
    }
    @ObservationIgnored private let storage: LibraryStorage
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var restorationClaimed = false
    @ObservationIgnored private var sessions: [UUID: BrowserSession] = [:]

    init(storageURL: URL? = nil) {
        spoofModeEnabled = UserDefaults.standard.bool(forKey: "spoofMode")
        let fileURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oasis", isDirectory: true).appendingPathComponent("Library.json")
        storage = LibraryStorage(url: fileURL)
        var loaded = LibraryData()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { loaded = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: fileURL)) }
            catch {
                storageError = "Oasis couldn’t read its library. The original file was preserved. \(error.localizedDescription)"
            }
        }
        if let links = loaded.essentials {
            for link in links where !loaded.bookmarks.contains(where: { $0.url == link.url && !$0.isReadingList }) {
                loaded.bookmarks.append(Bookmark(url: link.url, title: link.title))
            }
        }
        historyEntries = loaded.history
        bookmarkEntries = loaded.bookmarks
        spaceRecords = loaded.spaces
        windows = loaded.windows
    }

    var bookmarks: [Bookmark] { bookmarkEntries.filter { !$0.isReadingList } }
    var favorites: [Bookmark] { bookmarks.filter(\.isFavorite) }
    var readingList: [Bookmark] { bookmarkEntries.filter(\.isReadingList) }
    var history: [HistoryEntry] { historyEntries }
    var spaces: [BrowserSpace] {
        guard let spaces = spaceRecords, !spaces.isEmpty else { return BrowserSpace.defaults }
        return spaces
    }

    @discardableResult
    func addSpace(name: String, emoji: String) -> BrowserSpace? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, BrowserSpace.isValidEmoji(emoji) else { return nil }
        let space = BrowserSpace(name: name, emoji: emoji)
        spaceRecords = spaces + [space]
        persist()
        return space
    }

    func updateSpace(_ id: UUID, name: String, emoji: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, BrowserSpace.isValidEmoji(emoji), let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        var updated = spaces
        updated[index].name = name
        updated[index].emoji = emoji
        spaceRecords = updated
        persist()
    }

    @discardableResult
    func removeSpace(_ id: UUID) -> Bool {
        let remaining = spaces.filter { $0.id != id }
        guard !remaining.isEmpty, remaining.count != spaces.count else { return false }
        let fallback = remaining[0].id
        spaceRecords = remaining
        for session in sessions.values where !session.isPrivate {
            session.mergeSpace(id, into: fallback)
        }
        for key in Array(windows.keys) {
            guard var window = windows[key] else { continue }
            for index in window.tabs.indices where window.tabs[index].spaceID == id {
                window.tabs[index].spaceID = fallback
            }
            if window.selectedSpaceID == id { window.selectedSpaceID = fallback }
            window.selectedIndicesBySpace?.removeValue(forKey: id.uuidString)
            windows[key] = window
        }
        persist()
        return true
    }
    var searchEngine: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .duckDuckGo
    }

    func recordVisit(url: URL, title: String) {
        guard url.isWebURL else { return }
        if let first = historyEntries.first, first.url == url, Date().timeIntervalSince(first.visitedAt) < 10 {
            historyEntries[0].title = title
        } else { historyEntries.insert(HistoryEntry(url: url, title: title), at: 0) }
        let days = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        if days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            historyEntries.removeAll { $0.visitedAt < cutoff }
        }
        if historyEntries.count > 10_000 { historyEntries = Array(historyEntries.prefix(10_000)) }
        persist()
    }

    func addBookmark(url: URL, title: String, readingList: Bool = false) {
        guard !bookmarkEntries.contains(where: { $0.url == url && $0.isReadingList == readingList }) else { return }
        bookmarkEntries.append(Bookmark(url: url, title: title.isEmpty ? url.displayHost : title,
                                       isFavorite: !readingList, isReadingList: readingList))
        persist()
    }
    func updateBookmark(_ bookmark: Bookmark) {
        guard let index = bookmarkEntries.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarkEntries[index] = bookmark
        persist()
    }
    func removeBookmark(_ id: UUID) { bookmarkEntries.removeAll { $0.id == id }; persist() }
    func removeHistory(_ id: UUID) { historyEntries.removeAll { $0.id == id }; persist() }
    func clearHistory(since date: Date = .distantPast) {
        historyEntries.removeAll { $0.visitedAt >= date }
        persist()
    }
    func clearWebsiteData() async {
        isClearingWebsiteData = true
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        isClearingWebsiteData = false
    }

    func register(_ session: BrowserSession) {
        sessions[session.id] = session
    }
    func unregister(_ session: BrowserSession) {
        sessions.removeValue(forKey: session.id)
        windows.removeValue(forKey: session.id.uuidString)
        persist()
    }
    func claimRestoredWindows() -> [SavedWindow] {
        guard !restorationClaimed else { return [] }
        restorationClaimed = true
        let result = Array(windows.sorted { $0.key < $1.key }.map(\.value))
        windows = [:]
        return (UserDefaults.standard.object(forKey: "restoreSession") as? Bool ?? false) ? result : []
    }
    func saveSession(_ session: BrowserSession) {
        guard !session.isPrivate else { return }
        let snapshot = session.snapshot
        guard windows[session.id.uuidString] != snapshot else { return }
        windows[session.id.uuidString] = snapshot
        persist()
    }
    func flush() {
        saveTask?.cancel()
        for session in sessions.values where !session.isPrivate {
            windows[session.id.uuidString] = session.snapshot
        }
        guard storageError == nil else { return }
        do { try storage.flush(data) }
        catch { storageError = "Oasis couldn’t save your library. \(error.localizedDescription)" }
    }
    private func persist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.writeAsynchronously()
        }
    }
    private func writeAsynchronously() {
        // A failed load must never overwrite the recoverable original library.
        guard storageError == nil else { return }
        storage.schedule(data) { [weak self] result in
            if case .failure(let error) = result {
                Task { @MainActor [weak self] in
                    self?.storageError = "Oasis couldn’t save your library. \(error.localizedDescription)"
                }
            }
        }
    }

    func exportBookmarks() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Oasis Bookmarks.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let links = bookmarks.map { "<DT><A HREF=\"\(escape($0.url.absoluteString))\">\(escape($0.title))</A>" }.joined(separator: "\n")
        let html = "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Oasis Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n\(links)\n</DL><p>"
        do { try html.write(to: url, atomically: true, encoding: .utf8) }
        catch { storageError = error.localizedDescription }
    }

    func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let html = try String(contentsOf: url, encoding: .utf8)
            let regex = try NSRegularExpression(pattern: "<a\\b[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
                guard let link = URL(string: raw), link.isWebURL else { continue }
                let titleHTML = ns.substring(with: match.range(at: 2))
                let title = titleHTML.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                addBookmark(url: link, title: title)
            }
        } catch { storageError = error.localizedDescription }
    }
}
