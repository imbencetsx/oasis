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
  var currentSpaceID: UUID
  private var privateSpaces = BrowserSpace.defaults
  private var selectedBySpace: [UUID: UUID] = [:]
  @ObservationIgnored private var activated = false
  @ObservationIgnored private let privateStore: WKWebsiteDataStore?

  init(library: BrowserLibrary? = nil, isPrivate: Bool = false) {
    self.library = library ?? .shared
    self.isPrivate = isPrivate
    currentSpaceID = (isPrivate ? BrowserSpace.defaults : self.library.spaces)[0].id
    downloads = isPrivate ? BrowserDownloads() : .shared
    privateStore = isPrivate ? .nonPersistent() : nil
  }
  var spaces: [BrowserSpace] { isPrivate ? privateSpaces : library.spaces }
  var currentSpace: BrowserSpace { spaces.first { $0.id == currentSpaceID } ?? spaces[0] }
  var currentTabs: [BrowserTab] { tabs.filter { $0.spaceID == currentSpaceID } }
  var pinnedTabs: [BrowserTab] { currentTabs.filter(\.isPinned) }
  var unpinnedTabs: [BrowserTab] { currentTabs.filter { !$0.isPinned } }
  var selectedTab: BrowserTab? { currentTabs.first { $0.id == selectedID } }
  var snapshot: SavedWindow {
    var selections = selectedBySpace
    if let selectedID { selections[currentSpaceID] = selectedID }
    let indices = selections.reduce(into: [String: Int]()) { result, entry in
      if let index = tabs.firstIndex(where: { $0.id == entry.value && $0.spaceID == entry.key }) {
        result[entry.key.uuidString] = index
      }
    }
    return SavedWindow(
      tabs: tabs.map { SavedTab(url: $0.isBlankPage ? nil : $0.url, isPinned: $0.isPinned, spaceID: $0.spaceID) },
      selectedIndex: tabs.firstIndex { $0.id == selectedID } ?? 0,
      selectedSpaceID: currentSpaceID, selectedIndicesBySpace: indices)
  }
  func activate(restored: SavedWindow? = nil) {
    guard !activated else { return }
    activated = true
    library.register(self)
    if let restored {
      tabs.forEach { $0.close() }
      tabs = []
      selectedID = nil
      selectedBySpace = [:]
      if let id = restored.selectedSpaceID, spaces.contains(where: { $0.id == id }) { currentSpaceID = id }
      for saved in restored.tabs {
        let target = spaces.contains { $0.id == saved.spaceID } ? saved.spaceID : spaces[0].id
        let tab = newTab(url: saved.url, select: false, spaceID: target)
        tab.isPinned = saved.isPinned
      }
      for (key, index) in restored.selectedIndicesBySpace ?? [:] {
        if let id = UUID(uuidString: key), tabs.indices.contains(index), tabs[index].spaceID == id {
          selectedBySpace[id] = tabs[index].id
        }
      }
      if tabs.indices.contains(restored.selectedIndex) {
        let tab = tabs[restored.selectedIndex]
        if restored.selectedSpaceID == nil, let id = tab.spaceID { currentSpaceID = id }
        if tab.spaceID == currentSpaceID { selectedBySpace[currentSpaceID] = tab.id }
      }
      selectedID = selectedBySpace[currentSpaceID] ?? currentTabs.first?.id
    }
    showsNewTabSearch = false
    save()
  }
  @discardableResult
  func newTab(url: URL? = nil, select: Bool = true, configuration: WKWebViewConfiguration? = nil, spaceID: UUID? = nil)
    -> BrowserTab
  {
    let tab = BrowserTab(
      isPrivate: isPrivate, configuration: configuration, dataStore: privateStore,
      spoofModeEnabled: library.spoofModeEnabled)
    let target = spaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil } ?? currentSpaceID
    tab.session = self
    tab.spaceID = target
    if select && target != currentSpaceID { selectSpace(target) }
    tabs.append(tab)
    if select || (selectedID == nil && target == currentSpaceID) {
      selectedID = tab.id
      selectedBySpace[target] = tab.id
    }
    if let url { tab.load(url) }
    if select { showsNewTabSearch = false }
    save()
    return tab
  }
  /// The toolbar plus, sidebar button, and New Tab command present the search overlay.
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
    guard let tab = tabs.first(where: { $0.id == id }), let space = tab.spaceID else { return }
    if space != currentSpaceID { selectSpace(space) }
    selectedID = id
    selectedBySpace[currentSpaceID] = id
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
      closedTabs.append(SavedTab(url: tab.url, isPinned: tab.isPinned, spaceID: tab.spaceID))
      if closedTabs.count > 20 { closedTabs.removeFirst() }
    }
    tab.close()
    tabs.remove(at: index)
    if let space = tab.spaceID, selectedBySpace[space] == id { selectedBySpace.removeValue(forKey: space) }
    if selectedID == id {
      selectedID = currentTabs.first?.id
      if let selectedID { selectedBySpace[currentSpaceID] = selectedID }
    }
    if currentTabs.isEmpty { showsNewTabSearch = false }
    save()
  }
  func reopenClosedTab() {
    guard let saved = closedTabs.popLast() else { return }
    let tab = newTab(url: saved.url, spaceID: saved.spaceID)
    tab.isPinned = saved.isPinned
    sortPinned()
    save()
  }
  func togglePin(_ tab: BrowserTab) {
    tab.isPinned.toggle()
    sortPinned()
    save()
  }
  func selectSpace(_ id: UUID) {
    guard spaces.contains(where: { $0.id == id }), id != currentSpaceID else { return }
    if let selectedID { selectedBySpace[currentSpaceID] = selectedID }
    currentSpaceID = id
    let remembered = selectedBySpace[id]
    selectedID = currentTabs.first(where: { $0.id == remembered })?.id ?? currentTabs.first?.id
    showsFind = false
    showsNewTabSearch = false
    ClipboardTyping.shared.stop()
    save()
  }

  @discardableResult
  func addSpace(name: String, emoji: String) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, BrowserSpace.isValidEmoji(emoji) else { return false }
    let space: BrowserSpace
    if isPrivate {
      space = BrowserSpace(name: name, emoji: emoji)
      privateSpaces.append(space)
    } else {
      guard let created = library.addSpace(name: name, emoji: emoji) else { return false }
      space = created
    }
    selectSpace(space.id)
    return true
  }

  func updateSpace(_ id: UUID, name: String, emoji: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, BrowserSpace.isValidEmoji(emoji) else { return }
    if isPrivate {
      guard let index = privateSpaces.firstIndex(where: { $0.id == id }) else { return }
      privateSpaces[index].name = name
      privateSpaces[index].emoji = emoji
    } else { library.updateSpace(id, name: name, emoji: emoji) }
    save()
  }

  @discardableResult
  func removeSpace(_ id: UUID) -> Bool {
    let remaining = spaces.filter { $0.id != id }
    guard !remaining.isEmpty, remaining.count != spaces.count else { return false }
    if isPrivate { privateSpaces = remaining }
    mergeSpace(id, into: remaining[0].id)
    if !isPrivate { return library.removeSpace(id) }
    return true
  }

  func mergeSpace(_ id: UUID, into fallback: UUID) {
    for tab in tabs where tab.spaceID == id { tab.spaceID = fallback }
    selectedBySpace.removeValue(forKey: id)
    if currentSpaceID == id {
      currentSpaceID = fallback
      if !currentTabs.contains(where: { $0.id == selectedID }) { selectedID = currentTabs.first?.id }
      if let selectedID { selectedBySpace[fallback] = selectedID }
      showsNewTabSearch = false
      showsFind = false
      ClipboardTyping.shared.stop()
    }
    sortPinned()
    save()
  }

  @discardableResult
  func moveTabToSpace(_ tabID: UUID, to spaceID: UUID) -> Bool {
    guard spaces.contains(where: { $0.id == spaceID }), let tab = tabs.first(where: { $0.id == tabID }) else { return false }
    if tab.spaceID == spaceID { return true }
    if let old = tab.spaceID, selectedBySpace[old] == tabID { selectedBySpace.removeValue(forKey: old) }
    tab.spaceID = spaceID
    if selectedID == tabID { selectedID = currentTabs.first?.id }
    selectSpace(spaceID)
    select(tabID)
    return true
  }

  func clearCurrentSpace() {
    for id in unpinnedTabs.map(\.id) { closeTab(id) }
    showsFind = false
    showsNewTabSearch = false
    save()
  }
  private func sortPinned() { tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned } }
  @discardableResult
  func moveTab(_ source: UUID, before destination: UUID) -> Bool {
    guard let a = tabs.firstIndex(where: { $0.id == source }),
      let b = tabs.firstIndex(where: { $0.id == destination }), tabs[a].isPinned == tabs[b].isPinned, tabs[a].spaceID == tabs[b].spaceID
    else { return false }
    if source == destination { return true }
    let tab = tabs.remove(at: a)
    tabs.insert(tab, at: b > a ? b - 1 : b)
    save()
    return true
  }

  func cycleTab(_ offset: Int) {
    let ordered = currentTabs
    guard !ordered.isEmpty, let index = ordered.firstIndex(where: { $0.id == selectedID }) else { return }
    select(ordered[(index + offset + ordered.count) % ordered.count].id)
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
