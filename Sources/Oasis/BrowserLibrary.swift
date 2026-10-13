import SwiftUI
import WebKit

@MainActor @Observable
final class BrowserLibrary {
    static let shared = BrowserLibrary()
    private(set) var data: LibraryData
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
    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var restorationClaimed = false
    @ObservationIgnored private var sessions: [UUID: BrowserSession] = [:]

    init(storageURL: URL? = nil) {
        spoofModeEnabled = UserDefaults.standard.bool(forKey: "spoofMode")
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Oasis", isDirectory: true).appendingPathComponent("Library.json")
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do { data = try JSONDecoder().decode(LibraryData.self, from: Data(contentsOf: self.storageURL)) }
            catch {
                data = LibraryData()
                storageError = "Oasis couldn’t read its library. The original file was preserved. \(error.localizedDescription)"
            }
        } else { data = LibraryData() }
        if let links = data.essentials {
            for link in links where !data.bookmarks.contains(where: { $0.url == link.url && !$0.isReadingList }) {
                data.bookmarks.append(Bookmark(url: link.url, title: link.title))
            }
            data.essentials = nil
        }
    }

    var bookmarks: [Bookmark] { data.bookmarks.filter { !$0.isReadingList } }
    var favorites: [Bookmark] { bookmarks.filter(\.isFavorite) }
    var readingList: [Bookmark] { data.bookmarks.filter(\.isReadingList) }
    var history: [HistoryEntry] { data.history }
    var spaces: [BrowserSpace] {
        guard let spaces = data.spaces, !spaces.isEmpty else { return BrowserSpace.defaults }
        return spaces
    }

    @discardableResult
    func addSpace(name: String, emoji: String) -> BrowserSpace? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, BrowserSpace.isValidEmoji(emoji) else { return nil }
        let space = BrowserSpace(name: name, emoji: emoji)
        data.spaces = spaces + [space]
        persist()
        return space
    }

    func updateSpace(_ id: UUID, name: String, emoji: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, BrowserSpace.isValidEmoji(emoji), let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        var updated = spaces
        updated[index].name = name
        updated[index].emoji = emoji
        data.spaces = updated
        persist()
    }

    @discardableResult
    func removeSpace(_ id: UUID) -> Bool {
        let remaining = spaces.filter { $0.id != id }
        guard !remaining.isEmpty, remaining.count != spaces.count else { return false }
        let fallback = remaining[0].id
        data.spaces = remaining
        for session in sessions.values where !session.isPrivate {
            session.mergeSpace(id, into: fallback)
        }
        for key in Array(data.windows.keys) {
            guard var window = data.windows[key] else { continue }
            for index in window.tabs.indices where window.tabs[index].spaceID == id {
                window.tabs[index].spaceID = fallback
            }
            if window.selectedSpaceID == id { window.selectedSpaceID = fallback }
            window.selectedIndicesBySpace?.removeValue(forKey: id.uuidString)
            data.windows[key] = window
        }
        persist()
        return true
    }
    var searchEngine: SearchEngine {
        SearchEngine(rawValue: UserDefaults.standard.string(forKey: "searchEngine") ?? "") ?? .duckDuckGo
    }

    func recordVisit(url: URL, title: String) {
        guard url.isWebURL else { return }
        if let first = data.history.first, first.url == url, Date().timeIntervalSince(first.visitedAt) < 10 {
            data.history[0].title = title
        } else { data.history.insert(HistoryEntry(url: url, title: title), at: 0) }
        let days = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        if days > 0 { data.history.removeAll { $0.visitedAt < Date().addingTimeInterval(-Double(days) * 86400) } }
        if data.history.count > 10_000 { data.history = Array(data.history.prefix(10_000)) }
        persist()
    }

    func isBookmarked(_ url: URL?) -> Bool { bookmarks.contains { $0.url == url } }
    func addBookmark(url: URL, title: String, readingList: Bool = false) {
        guard !data.bookmarks.contains(where: { $0.url == url && $0.isReadingList == readingList }) else { return }
        data.bookmarks.append(Bookmark(url: url, title: title.isEmpty ? url.displayHost : title,
                                       isFavorite: !readingList, isReadingList: readingList))
        persist()
    }
    func updateBookmark(_ bookmark: Bookmark) {
        guard let index = data.bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        data.bookmarks[index] = bookmark
        persist()
    }
    func removeBookmark(_ id: UUID) { data.bookmarks.removeAll { $0.id == id }; persist() }
    func removeHistory(_ id: UUID) { data.history.removeAll { $0.id == id }; persist() }
    func clearHistory(since date: Date = .distantPast) {
        data.history.removeAll { $0.visitedAt >= date }
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
        data.windows.removeValue(forKey: session.id.uuidString)
        persist()
    }
    func claimRestoredWindows() -> [SavedWindow] {
        guard !restorationClaimed else { return [] }
        restorationClaimed = true
        let result = Array(data.windows.sorted { $0.key < $1.key }.map(\.value))
        data.windows = [:]
        return (UserDefaults.standard.object(forKey: "restoreSession") as? Bool ?? false) ? result : []
    }
    func saveSession(_ session: BrowserSession) {
        guard !session.isPrivate else { return }
        data.windows[session.id.uuidString] = session.snapshot
        persist()
    }
    func flush() {
        saveTask?.cancel()
        for session in sessions.values where !session.isPrivate {
            data.windows[session.id.uuidString] = session.snapshot
        }
        write()
    }
    private func persist() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }
    private func write() {
        // A failed load must never overwrite the recoverable original library.
        guard storageError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: storageURL, options: .atomic)
        } catch { storageError = "Oasis couldn’t save your library. \(error.localizedDescription)" }
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
