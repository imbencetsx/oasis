import AppKit
import SwiftUI

enum BrowserPageFrame {
  static let inset: CGFloat = 6
  static let cornerRadius: CGFloat = 12
}

extension Color {
  static let oasisAccent = Color(
    nsColor: NSColor(name: nil) { appearance in
      if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        return NSColor(red: 1, green: 0.38, blue: 0.42, alpha: 1)
      }
      return NSColor(red: 0.76, green: 0.12, blue: 0.20, alpha: 1)
    })
}

struct BrowserWindowHost: View {
  let request: BrowserWindowRequest?
  @State private var session: BrowserSession
  @State private var hasAppeared = false
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage("appearance") private var appearance = "System"

  init(request: BrowserWindowRequest?) {
    self.request = request
    _session = State(initialValue: BrowserSession(isPrivate: request?.isPrivate ?? false))
  }
  var body: some View {
    BrowserWindow(session: session)
      .preferredColorScheme(appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil)
      .focusedSceneValue(\.browserSession, session)
      .background(WindowLifecycleView(showsSidebar: session.showsTabSidebar, reduceMotion: reduceMotion) { session.shutdown() })
      .task {
        guard !hasAppeared else { return }
        hasAppeared = true
        if session.isPrivate {
          session.activate()
        } else if let restored = request?.restored {
          session.activate(restored: restored)
        } else {
          let windows = session.library.claimRestoredWindows()
          session.activate(restored: windows.first)
          for window in windows.dropFirst() {
            openWindow(value: BrowserWindowRequest(restored: window))
          }
        }
      }
      .onOpenURL { url in
        if url.isWebURL || url.isFileURL { session.newTab(url: url) }
      }
  }
}

struct BrowserWindow: View {
  @Bindable var session: BrowserSession
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    ZStack {
      BrowserBackdrop(tab: session.selectedTab)
      HStack(spacing: 0) {
        TabSidebar(session: session)
          .overlay(alignment: .top) {
            WindowDragArea().frame(height: TabSidebar.topInset)
          }
          .frame(width: 224)
          .environment(\.colorScheme, session.selectedTab?.sidebarColorScheme ?? colorScheme)
          .offset(x: session.showsTabSidebar ? 0 : -224)
          .opacity(session.showsTabSidebar ? 1 : 0)
          .frame(width: session.showsTabSidebar ? 224 : 0, alignment: .leading)
          .clipped()
          .allowsHitTesting(session.showsTabSidebar)
          .accessibilityHidden(!session.showsTabSidebar)
        ZStack(alignment: .top) {
          BrowserViewport(session: session)
          if let color = session.selectedTab?.chromeColor {
            Color(nsColor: color)
              .frame(height: session.showsFind ? 112 : 64)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
          // Never put a native drag view beneath an editable field or button.
          VStack(spacing: 0) {
            WindowDragArea().frame(height: 10)
            Color.clear.frame(height: 42).allowsHitTesting(false)
            WindowDragArea().frame(height: 12)
          }
          .frame(height: 64)
          VStack(spacing: 8) {
            BrowserChrome(session: session)
            if session.showsFind, let tab = session.selectedTab, !tab.isBlankPage {
              FindBar(tab: tab, isPresented: $session.showsFind)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 14)
            }
          }
          .environment(\.colorScheme, session.selectedTab?.chromeColorScheme ?? colorScheme)
          .padding(.top, 12)
          .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: BrowserPageFrame.cornerRadius, style: .continuous))
        .padding(BrowserPageFrame.inset)
      }
      .animation(reduceMotion ? nil : .spring(duration: 0.36, bounce: 0.08), value: session.showsTabSidebar)
      .allowsHitTesting(!session.showsNewTabSearch)
      .accessibilityHidden(session.showsNewTabSearch)
      if session.showsNewTabSearch {
        NewTabSearch(session: session)
          .id(session.selectedID)
          .zIndex(1)
      }
    }
    .ignoresSafeArea()
    .containerBackground(.clear, for: .window)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .frame(minWidth: 900, minHeight: 560)
    .navigationTitle(session.selectedTab?.title ?? "[oasis]")
    .sheet(isPresented: $session.showsLibraryPanel) {
      LibraryPanel(session: session)
        .frame(width: 440, height: 600)
        .tint(Color.oasisAccent)
    }
    .alert(
      "[oasis]",
      isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })
    ) {
      Button("OK") { session.notice = nil }
    } message: {
      Text(session.notice ?? "")
    }
    .onChange(of: session.library.storageError) { _, error in
      if let error { session.notice = error }
    }
    .onAppear { if let error = session.library.storageError { session.notice = error } }
  }
}

struct BrowserViewport: View {
  let session: BrowserSession
  var body: some View {
    ZStack(alignment: .top) {
      if let tab = session.selectedTab {
        if tab.isBlankPage {
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Empty Tab")
        } else {
          WebContentView(tab: tab).id(tab.id)
            .opacity(tab.errorMessage == nil && !tab.showsReader ? 1 : 0)
            .accessibilityHidden(tab.errorMessage != nil || tab.showsReader)
          if let message = tab.errorMessage {
            ContentUnavailableView {
              Label("This page couldn’t be opened", systemImage: "network.slash")
            } description: {
              Text(message).textSelection(.enabled)
              Text(tab.url?.absoluteString ?? "").font(.caption).foregroundStyle(.secondary)
            } actions: {
              Button("Try Again") { tab.reload() }.buttonStyle(.borderedProminent)
              Button("Open a New Tab") { session.newTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          if tab.showsReader, let article = tab.readerContent {
            ReaderView(article: article, tab: tab).padding(.top, 64)
          }
        }
        if tab.isLoading && !tab.isBlankPage {
          ProgressView(value: max(0.03, tab.progress))
            .tint(Color.oasisAccent)
            .controlSize(.mini)
            .padding(.horizontal, 24).padding(.top, 59)
            .accessibilityLabel("Loading page")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: session.selectedID, initial: true) { updateContentInset() }
    .onChange(of: session.showsFind) { updateContentInset() }
  }
  private func updateContentInset() {
    session.selectedTab?.setTopInset(session.showsFind ? 112 : 64)
  }
}

struct BrowserChrome: View {
  @Bindable var session: BrowserSession
  var body: some View {
    GlassEffectContainer(spacing: 10) {
      HStack(spacing: 12) {
        HStack(spacing: 10) {
          ChromeButton("Toggle Tabs", systemImage: "sidebar.left") {
            session.showsTabSidebar.toggle()
          }
          ChromeButton("New Tab (⌘T)", systemImage: "plus") {
            session.openNewTabSearch()
          }
          ChromeButton(
            session.selectedTab?.isLoading == true ? "Stop Loading" : "Refresh (⌘R)",
            systemImage: session.selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise"
          ) {
            if session.selectedTab?.isLoading == true {
              session.selectedTab?.stop()
            } else {
              session.selectedTab?.reload()
            }
          }.disabled(session.selectedTab?.isBlankPage ?? true)
          GlassChrome {
            HStack(spacing: 0) {
              Button {
                session.selectedTab?.goBack()
              } label: {
                Label("Back", systemImage: "chevron.left")
                  .frame(width: 37, height: 38).contentShape(Rectangle())
              }
              .disabled(!(session.selectedTab?.canGoBack ?? false)).help("Back (⌘[)")
              .contextMenu {
                if let tab = session.selectedTab {
                  ForEach(Array(tab.webView.backForwardList.backList.reversed()), id: \.url) {
                    item in
                    Button(item.title ?? item.url.displayHost) { tab.webView.go(to: item) }
                  }
                }
              }
              Button {
                session.selectedTab?.goForward()
              } label: {
                Label("Forward", systemImage: "chevron.right")
                  .frame(width: 37, height: 38).contentShape(Rectangle())
              }
              .disabled(!(session.selectedTab?.canGoForward ?? false)).help("Forward (⌘])")
            }
            .labelStyle(.iconOnly).buttonStyle(OasisButtonStyle())
            .font(.system(size: 13, weight: .medium))
            .frame(width: 74, height: 38)
          }
        }.frame(width: 230, alignment: .leading)
        Spacer(minLength: 0).background { WindowDragArea().frame(height: 38) }
        AddressBar(session: session).frame(minWidth: 160, maxWidth: 560).layoutPriority(1)
        Spacer(minLength: 0).background { WindowDragArea().frame(height: 38) }
        HStack(spacing: 10) {
          ChromeButton(
            "Downloads",
            systemImage: session.downloads.activeCount > 0
              ? "arrow.down.circle.fill" : "arrow.down.circle"
          ) {
            session.showsDownloads.toggle()
          }
          .popover(isPresented: $session.showsDownloads) {
            DownloadsPanel(downloads: session.downloads)
          }
          GlassChrome {
            Toggle(isOn: Binding(
              get: { session.library.spoofModeEnabled },
              set: { session.library.spoofModeEnabled = $0 }
            )) {
              Image(systemName: session.library.spoofModeEnabled ? "theatermasks.fill" : "theatermasks")
                .font(.system(size: 15)).foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(.primary.opacity(session.library.spoofModeEnabled ? 0.12 : 0), in: Capsule())
                .contentShape(Rectangle())
            }
            .toggleStyle(.button).buttonStyle(OasisButtonStyle()).tint(.primary)
            .help(session.library.spoofModeEnabled ? "Spoof Mode: On" : "Spoof Mode: Off")
            .accessibilityLabel("Spoof Mode")
            .accessibilityValue(session.library.spoofModeEnabled ? "On" : "Off")
          }
          if let url = session.selectedTab?.url, !(session.selectedTab?.isBlankPage ?? true) {
            GlassChrome {
              ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
                  .labelStyle(.iconOnly).frame(width: 38, height: 38)
                  .contentShape(Rectangle())
              }.buttonStyle(OasisButtonStyle()).help("Share this page")
            }
          }
          GlassChrome {
            Menu {
              Button("Add Bookmark", systemImage: "bookmark") { session.bookmarkCurrent() }
                .disabled(session.selectedTab?.isBlankPage ?? true)
              Button("Add to Reading List", systemImage: "eyeglasses") {
                session.bookmarkCurrent(readingList: true)
              }
              .disabled(session.selectedTab?.isBlankPage ?? true)
              Divider()
              Button("History", systemImage: "clock") { session.showLibrary(.history) }
              Button("Bookmarks", systemImage: "book.closed") { session.showLibrary(.bookmarks) }
              Button("Reading List", systemImage: "eyeglasses") {
                session.showLibrary(.readingList)
              }
              Divider()
              Button("Reader", systemImage: "doc.text") { session.selectedTab?.toggleReader() }
                .disabled(session.selectedTab?.isBlankPage ?? true)
              Button("Find on Page", systemImage: "magnifyingglass") { session.showsFind = true }
                .disabled(session.selectedTab?.isBlankPage ?? true)
              Divider()
              Button("Export PDF…") { session.selectedTab?.savePDF() }.disabled(
                session.selectedTab?.isBlankPage ?? true)
              Button("Print…") { session.selectedTab?.printPage() }.disabled(
                session.selectedTab?.isBlankPage ?? true)
              Divider()
              Toggle(
                "Spoof Mode",
                isOn: Binding(
                  get: { session.library.spoofModeEnabled },
                  set: { session.library.spoofModeEnabled = $0 }
                ))
              SettingsLink()
            } label: {
              Image(systemName: "ellipsis").font(.system(size: 17)).foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(OasisButtonStyle()).menuIndicator(.hidden)
            .tint(.primary).frame(width: 38, height: 38)
            .help("Page actions").accessibilityLabel("Page actions")
          }
        }.frame(width: 230, alignment: .trailing)
      }
    }
  }
}

/// A glass capsule with composable content; the caller owns the controls and their state.
struct GlassChrome<Content: View>: View {
  let content: Content
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  init(@ViewBuilder content: () -> Content) { self.content = content() }
  var body: some View {
    if reduceTransparency {
      content.background(.background, in: Capsule())
    } else {
      content.glassEffect(.regular, in: .capsule)
    }
  }
}

struct ChromeButton: View {
  let title: LocalizedStringResource
  let systemImage: String
  let action: () -> Void
  init(_ title: LocalizedStringResource, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }
  var body: some View {
    Button(action: action) {
      GlassChrome {
        Label {
          Text(title)
        } icon: {
          Image(systemName: systemImage)
        }
        .labelStyle(.iconOnly).font(.system(size: 15))
        .frame(width: 38, height: 38)
        .contentShape(Rectangle())
      }
    }.buttonStyle(OasisButtonStyle()).help(Text(title))
  }
}

struct AddressBar: View {
  @Bindable var session: BrowserSession
  @State private var text = ""
  @State private var showsInfo = false
  @State private var suggestionSelection: String?
  @State private var addressFocusToken = UUID()
  @State private var isFocused = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var tab: BrowserTab? { session.selectedTab }
  private var suggestions: [AddressSuggestion] {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    var matches = AddressSuggestions.matches(
      query, bookmarks: session.library.bookmarks,
      history: session.isPrivate ? [] : session.library.history)
    if let destination = AddressResolver.resolve(query, engine: session.library.searchEngine),
      !matches.contains(where: { $0.url == destination })
    {
      let isSearch = destination == session.library.searchEngine.searchURL(for: query)
      let action = AddressSuggestion(
        url: destination,
        title: isSearch
          ? "Search \(session.library.searchEngine.rawValue) for “\(query)”"
          : "Go to \(destination.displayHost)",
        symbol: isSearch ? "magnifyingglass" : "arrow.right")
      if isSearch { matches.append(action) } else { matches.insert(action, at: 0) }
    }
    return Array(matches.prefix(7))
  }
  private var effectiveSuggestionID: String? { suggestionSelection ?? suggestions.first?.id }
  var body: some View {
    HStack(spacing: 0) {
      Button {
        showsInfo.toggle()
      } label: {
        Image(
          systemName: session.isPrivate
            ? "hand.raised.slash" : tab?.url?.scheme == "https" ? "lock" : "globe"
        )
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .frame(width: 30, height: 38).contentShape(Rectangle())
      }
      .buttonStyle(OasisButtonStyle()).help("Website information")
      .popover(isPresented: $showsInfo) {
        VStack(alignment: .leading, spacing: 10) {
          Label(
            session.isPrivate ? "Private Browsing" : "Website Information",
            systemImage: session.isPrivate ? "hand.raised.slash" : "globe"
          )
          .font(.headline)
          Text(tab?.url?.displayHost ?? "about:blank").textSelection(.enabled)
          Text(
            tab?.url?.scheme == "https"
              ? "The connection to this website is encrypted."
              : "This page does not use an HTTPS connection."
          )
          .font(.callout).foregroundStyle(.secondary)
          if session.isPrivate {
            Text(
              "History and tabs in this window are not saved. Downloads and bookmarks you create are kept."
            ).font(.caption)
          }
        }.padding(20).frame(width: 300)
      }
      .frame(width: 60, alignment: .leading)
      NativeAddressField(
        text: $text, isFocused: $isFocused, focusToken: addressFocusToken,
        onSubmit: {
          if let suggestion = suggestions.first(where: { $0.id == effectiveSuggestionID }) {
            session.navigate(to: suggestion.url)
          } else {
            session.navigate(text)
          }
          isFocused = false
        },
        onMove: { offset in
          suggestionSelection = AddressSuggestions.moveSelection(
            effectiveSuggestionID, in: suggestions, by: offset)
        },
        onEscape: {
          if suggestionSelection != nil {
            suggestionSelection = nil
          } else {
            isFocused = false
            updateText()
          }
        }
      )
      .frame(maxWidth: .infinity).frame(height: 38)
      HStack(spacing: 0) {
        if let tab, !tab.isBlankPage {
          if tab.zoom != 1 {
            Button {
              tab.setZoom(1)
            } label: {
              Text("\(Int(tab.zoom * 100))%")
                .font(.caption2).frame(minWidth: 30, minHeight: 38)
                .contentShape(Rectangle())
            }.buttonStyle(OasisButtonStyle()).help("Reset zoom")
          }
        }
      }.frame(width: 60, alignment: .trailing)
    }
    .padding(.horizontal, 8).frame(height: 38)
    .background {
      Button(action: focus) {
        Capsule().fill(.clear).contentShape(Capsule())
      }.buttonStyle(.plain)
        .accessibilityLabel("Edit address")
    }
    // Apply glass to its content as a single control, so it never filters the text above it.
    .glassEffect(.regular, in: .capsule)
    .overlay(
      Capsule().stroke(isFocused ? Color.oasisAccent.opacity(0.35) : .clear, lineWidth: 1.5)
        .scaleEffect(x: reduceMotion || !isFocused ? 1 : 1.006, y: reduceMotion || !isFocused ? 1 : 1.045)
        .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.25), value: isFocused)
        .allowsHitTesting(false)
    )
    .overlay(alignment: .top) {
      if isFocused && !suggestions.isEmpty {
        AddressSuggestionList(suggestions: suggestions, selection: effectiveSuggestionID) {
          suggestion in
          session.navigate(to: suggestion.url)
          isFocused = false
        }.padding(.top, 48)
      }
    }
    .onChange(of: text) { suggestionSelection = nil }
    .onChange(of: session.selectedID) {
      isFocused = false
      updateText()
    }
    .onChange(of: tab?.url) { if !isFocused { updateText() } }
    .onChange(of: session.focusAddressToken) { focus() }
    .onAppear { updateText() }
  }
  private func updateText() {
    text = tab?.url?.absoluteString ?? ""
    suggestionSelection = nil
  }
  private func focus() {
    if !isFocused { updateText() }
    addressFocusToken = UUID()
    isFocused = true
  }
}

// AppKit supplies transparent window backing and the window-close lifecycle.
struct WindowLifecycleView: NSViewRepresentable {
  var showsSidebar: Bool
  var reduceMotion: Bool
  var onClose: () -> Void
  func makeNSView(context: Context) -> CloseObserverView {
    let view = CloseObserverView(onClose: onClose)
    view.configureTrafficLights(showsSidebar: showsSidebar, reduceMotion: reduceMotion)
    return view
  }
  func updateNSView(_ nsView: CloseObserverView, context: Context) {
    nsView.onClose = onClose
    nsView.configureTrafficLights(showsSidebar: showsSidebar, reduceMotion: reduceMotion)
  }
}
final class CloseObserverView: NSView {
  var onClose: () -> Void
  private var observers: [NSObjectProtocol] = []
  private var trafficLights: WindowTrafficLights?
  private var showsSidebar = true
  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func configureTrafficLights(showsSidebar: Bool, reduceMotion: Bool) {
    self.showsSidebar = showsSidebar
    trafficLights?.update(visible: showsSidebar, animated: !reduceMotion)
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    trafficLights?.restore()
    trafficLights = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    guard let window else { return }
    window.isMovableByWindowBackground = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.titlebarAppearsTransparent = true
    trafficLights = WindowTrafficLights(window: window)
    trafficLights?.update(visible: showsSidebar, animated: false)
    observers.append(NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.onClose() } })
    for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.trafficLights?.update(visible: self.showsSidebar, animated: false, force: true)
        }
      })
    }
  }
  isolated deinit {
    trafficLights?.restore()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }
}

private struct BrowserBackdrop: View {
  let tab: BrowserTab?
  @AppStorage(BackgroundGrain.preferenceKey) private var grain = BackgroundGrain.defaultIntensity
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    WindowBackdrop()
      .overlay {
        if let color = tab?.sidebarTint { Color(nsColor: color).opacity(0.35) }
        else { Rectangle().fill(.thinMaterial.opacity(0.28)) }
      }
      .environment(\.colorScheme, tab?.sidebarColorScheme ?? colorScheme)
      .overlay { BackgroundGrain(intensity: grain) }
      .allowsHitTesting(false)
  }
}

/// The window's system vibrancy material blends with the desktop behind Oasis.
struct WindowBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .underWindowBackground
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }
  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
