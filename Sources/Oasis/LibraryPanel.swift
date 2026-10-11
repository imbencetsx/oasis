import SwiftUI

struct LibraryPanel: View {
    @Bindable var session: BrowserSession
    @State private var search = ""
    @State private var editing: Bookmark?
    @State private var creating = false
    @State private var showsClearHistory = false
    @State private var clearRange = "All history"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("Library").font(.system(size: 18, weight: .semibold, design: .serif))
                Spacer()
                Button("Done") { session.showsLibraryPanel = false }
                    .buttonStyle(OasisButtonStyle()).font(.caption).keyboardShortcut(.cancelAction)
                if session.sidebarSection == .bookmarks {
                    Button("Add Bookmark", systemImage: "plus") { creating = true }.buttonStyle(OasisButtonStyle()).labelStyle(.iconOnly)
                }
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 20)
            HStack(spacing: 4) {
                ForEach(SidebarSection.allCases) { section in
                    Button { session.sidebarSection = section; search = "" } label: {
                        Image(systemName: section.symbol).frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(session.sidebarSection == section ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(OasisButtonStyle()).help(section.rawValue).accessibilityLabel(section.rawValue)
                }
            }.padding(.horizontal, 12)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(session.sidebarSection.rawValue.lowercased())", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(9).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            HStack {
                Text(session.sidebarSection.rawValue.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if session.sidebarSection == .history {
                    Button("Clear…") { showsClearHistory = true }.font(.caption).buttonStyle(OasisButtonStyle()).foregroundStyle(.secondary)
                        .disabled(session.library.history.isEmpty)
                }
            }.padding(.horizontal, 17).padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if session.sidebarSection == .history { historyRows }
                    else { bookmarkRows }
                }.padding(.horizontal, 8).padding(.bottom, 10)
            }
            Divider()
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }.buttonStyle(OasisButtonStyle()).font(.caption)
                Spacer()
                if session.isPrivate { Image(systemName: "hand.raised.slash").help("Private Window") }
            }.foregroundStyle(.secondary).padding(16)
        }
        .sheet(item: $editing) { bookmark in
            BookmarkEditor(bookmark: bookmark) { session.library.updateBookmark($0) }
        }
        .sheet(isPresented: $creating) {
            BookmarkEditor(bookmark: Bookmark(url: URL(string: "https://example.com")!, title: ""), isNew: true) { bookmark in
                session.library.addBookmark(url: bookmark.url, title: bookmark.title)
            }
        }
        .sheet(isPresented: $showsClearHistory) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Clear browsing history").font(.title2.bold())
                Text("Remove visited pages from your Oasis history. Bookmarks and website data are kept.").foregroundStyle(.secondary)
                Picker("Clear", selection: $clearRange) {
                    ForEach(["Last hour", "Today", "All history"], id: \.self) { Text($0) }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showsClearHistory = false }.keyboardShortcut(.cancelAction)
                    Button("Clear History", role: .destructive) {
                        let date = clearRange == "Last hour" ? Date().addingTimeInterval(-3600) : clearRange == "Today" ? Calendar.current.startOfDay(for: Date()) : .distantPast
                        session.library.clearHistory(since: date); showsClearHistory = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(26).frame(width: 410)
        }
    }
    private var filteredHistory: [HistoryEntry] {
        session.library.history.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.absoluteString.localizedCaseInsensitiveContains(search) }
    }
    @ViewBuilder private var historyRows: some View {
        let grouped = Dictionary(grouping: filteredHistory) { Calendar.current.startOfDay(for: $0.visitedAt) }
        if grouped.isEmpty { emptyState("No history here", detail: search.isEmpty ? "The pages you visit appear here." : "Try a different search.") }
        ForEach(grouped.keys.sorted(by: >), id: \.self) { date in
            Text(date, format: .dateTime.month(.abbreviated).day().weekday(.abbreviated))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
            ForEach(grouped[date] ?? []) { entry in
                Button { session.navigate(to: entry.url) } label: {
                    LibraryRow(url: entry.url, title: entry.title, subtitle: entry.url.displayHost)
                }.buttonStyle(OasisButtonStyle()).help(entry.url.absoluteString)
                    .contextMenu {
                        Button("Open in New Tab") { session.newTab(url: entry.url) }
                        Button("Add Bookmark") { session.library.addBookmark(url: entry.url, title: entry.title) }
                        Divider()
                        Button("Delete from History", role: .destructive) { session.library.removeHistory(entry.id) }
                    }
            }
        }
    }
    @ViewBuilder private var bookmarkRows: some View {
        let items = (session.sidebarSection == .readingList ? session.library.readingList : session.library.bookmarks)
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.absoluteString.localizedCaseInsensitiveContains(search) }
        if items.isEmpty { emptyState(session.sidebarSection == .readingList ? "Save something for later" : "Your favorite places", detail: search.isEmpty ? "Save a page using the toolbar menu or ⌘D." : "Try a different search.") }
        ForEach(items) { bookmark in
            Button {
                session.navigate(to: bookmark.url)
                if bookmark.isReadingList { var read = bookmark; read.isRead = true; session.library.updateBookmark(read) }
            } label: {
                HStack(spacing: 0) {
                    LibraryRow(url: bookmark.url, title: bookmark.title, subtitle: bookmark.url.displayHost)
                    if bookmark.isReadingList && !bookmark.isRead { Circle().fill(Color.oasisAccent).frame(width: 6, height: 6).padding(.trailing, 12).accessibilityLabel("Unread") }
                }
            }.buttonStyle(OasisButtonStyle()).help(bookmark.url.absoluteString)
                .contextMenu {
                    Button("Open in New Tab") { session.newTab(url: bookmark.url) }
                    Button("Edit…") { editing = bookmark }
                    if bookmark.isReadingList {
                        Button(bookmark.isRead ? "Mark as Unread" : "Mark as Read") {
                            var changed = bookmark; changed.isRead.toggle(); session.library.updateBookmark(changed)
                        }
                    } else {
                        Button(bookmark.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            var changed = bookmark; changed.isFavorite.toggle(); session.library.updateBookmark(changed)
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { session.library.removeBookmark(bookmark.id) }
                }
        }
    }
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: session.sidebarSection.symbol).font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.top, 45)
    }
}

struct LibraryRow: View {
    let url: URL
    let title: String
    let subtitle: String
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(url: url)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? url.displayHost : title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.padding(9).contentShape(RoundedRectangle(cornerRadius: 8))
            .background(hovering ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

struct BookmarkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bookmark: Bookmark
    @State private var address: String
    let isNew: Bool
    let onSave: (Bookmark) -> Void
    init(bookmark: Bookmark, isNew: Bool = false, onSave: @escaping (Bookmark) -> Void) {
        _bookmark = State(initialValue: bookmark)
        _address = State(initialValue: isNew ? "" : bookmark.url.absoluteString)
        self.isNew = isNew; self.onSave = onSave
    }
    private var validURL: URL? {
        guard let url = URL(string: address), url.isWebURL, url.host != nil else { return nil }
        return url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isNew ? "Add Bookmark" : "Edit Bookmark").font(.title2.bold())
            Form {
                TextField("Title", text: $bookmark.title)
                TextField("Address", text: $address)
                if !bookmark.isReadingList { Toggle("Show in Favorites", isOn: $bookmark.isFavorite) }
            }
            if validURL == nil { Text("Enter a complete http:// or https:// address.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let url = validURL else { return }
                    bookmark.url = url; onSave(bookmark); dismiss()
                }.keyboardShortcut(.defaultAction).disabled(validURL == nil || bookmark.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(26).frame(width: 410)
    }
}
