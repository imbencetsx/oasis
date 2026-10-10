import SwiftUI
import WebKit

@MainActor @Observable
final class BrowserSession: Identifiable {
  let id = UUID()
  let isPrivate: Bool
  let library: BrowserLibrary
  let downloads: BrowserDownloads
  var tabs: [BrowserTab] = []
  var selectedID: UUID?
  var showsTabSidebar = true
  var showsLibraryPanel = false
  var sidebarSection: SidebarSection = .bookmarks
  var showsDownloads = false
  var showsFind = false
  var showsNewTabSearch = false
  var focusAddressToken = UUID()
  var notice: String?
  var closedTabs: [SavedTab] = []
  @ObservationIgnored private var activated = false
  @ObservationIgnored private let privateStore: WKWebsiteDataStore?

  init(library: BrowserLibrary? = nil, isPrivate: Bool = false) {
    self.library = library ?? .shared
    self.isPrivate = isPrivate
    downloads = isPrivate ? BrowserDownloads() : .shared
    privateStore = isPrivate ? .nonPersistent() : nil
  }
  var selectedTab: BrowserTab? { tabs.first { $0.id == selectedID } }
  var snapshot: SavedWindow {
    SavedWindow(
      tabs: tabs.map { SavedTab(url: $0.isBlankPage ? nil : $0.url, isPinned: $0.isPinned) },
      selectedIndex: tabs.firstIndex { $0.id == selectedID } ?? 0)
  }
  func activate(restored: SavedWindow? = nil) {
    guard !activated else { return }
    activated = true
    library.register(self)
    if let restored, !restored.tabs.isEmpty {
      tabs.forEach { $0.close() }
      tabs = []
      for saved in restored.tabs {
        let tab = newTab(url: saved.url, select: false)
        tab.isPinned = saved.isPinned
      }
      selectedID = tabs[min(max(0, restored.selectedIndex), tabs.count - 1)].id
    }
    showsNewTabSearch = false
    save()
  }
  @discardableResult
  func newTab(url: URL? = nil, select: Bool = true, configuration: WKWebViewConfiguration? = nil)
    -> BrowserTab
  {
    let tab = BrowserTab(
      isPrivate: isPrivate, configuration: configuration, dataStore: privateStore,
      spoofModeEnabled: library.spoofModeEnabled)
    tab.session = self
    tabs.append(tab)
    if select || selectedID == nil { selectedID = tab.id }
    if let url { tab.load(url) }
    if select { showsNewTabSearch = false }
    save()
    return tab
  }
  /// Only the toolbar plus and New Tab command present the search overlay.
  func openNewTabSearch() {
    showsNewTabSearch = true
  }
  func navigate(_ text: String) {
    guard let url = AddressResolver.resolve(text, engine: library.searchEngine) else { return }
    navigate(to: url)
  }
  func navigate(to url: URL) {
    if let tab = selectedTab { tab.load(url) } else { newTab(url: url) }
  }
  func select(_ id: UUID) {
    selectedID = id
    showsFind = false
    showsNewTabSearch = false
    save()
  }
  func focusLocation() {
    showsNewTabSearch = false
    focusAddressToken = UUID()
  }
  func closeTab(_ id: UUID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = tabs[index]
    if !isPrivate && !tab.isBlankPage {
      closedTabs.append(SavedTab(url: tab.url, isPinned: tab.isPinned))
      if closedTabs.count > 20 { closedTabs.removeFirst() }
    }
    tab.close()
    tabs.remove(at: index)
    if tabs.isEmpty {
      selectedID = nil
      showsNewTabSearch = false
    } else if selectedID == id {
      selectedID = tabs[min(index, tabs.count - 1)].id
    }
    save()
  }
  func reopenClosedTab() {
    guard let saved = closedTabs.popLast() else { return }
    let tab = newTab(url: saved.url)
    tab.isPinned = saved.isPinned
    sortPinned()
    save()
  }
  func togglePin(_ tab: BrowserTab) {
    tab.isPinned.toggle()
    sortPinned()
    save()
  }
  private func sortPinned() { tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned } }
  func moveTab(_ source: UUID, before destination: UUID) {
    guard source != destination, let a = tabs.firstIndex(where: { $0.id == source }),
      let b = tabs.firstIndex(where: { $0.id == destination }), tabs[a].isPinned == tabs[b].isPinned
    else { return }
    let tab = tabs.remove(at: a)
    tabs.insert(tab, at: b)
    save()
  }
  func cycleTab(_ offset: Int) {
    guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
    select(tabs[(index + offset + tabs.count) % tabs.count].id)
  }
  func showLibrary(_ section: SidebarSection) {
    sidebarSection = section
    showsLibraryPanel = true
  }
  func bookmarkCurrent(readingList: Bool = false) {
    guard let tab = selectedTab, let url = tab.url, !tab.isBlankPage else { return }
    library.addBookmark(url: url, title: tab.title, readingList: readingList)
    showLibrary(readingList ? .readingList : .bookmarks)
  }
  func save() { if activated { library.saveSession(self) } }
  func shutdown() {
    guard activated else { return }
    if !AppLifecycle.isTerminating { library.unregister(self) }
    tabs.forEach { $0.close() }
    if isPrivate { downloads.cancelAll() }
    activated = false
  }
  func openFile() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    navigate(to: url)
  }
}

struct BrowserWindowRequest: Codable, Hashable {
  var id = UUID()
  var isPrivate = false
  var restored: SavedWindow?
}

struct BrowserSessionKey: FocusedValueKey { typealias Value = BrowserSession }
extension FocusedValues {
  var browserSession: BrowserSession? {
    get { self[BrowserSessionKey.self] }
    set { self[BrowserSessionKey.self] = newValue }
  }
}
