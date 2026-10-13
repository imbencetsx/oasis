import SwiftUI
import CoreText
import AppKit

@MainActor enum AppLifecycle { static var isTerminating = false }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycle.isTerminating = true
        BrowserLibrary.shared.flush()
        return .terminateNow
    }
}

@main struct OasisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() {
        if let font = Bundle.main.url(forResource: "GeistMono-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        UserDefaults.standard.register(defaults: [
            "restoreSession": false, "searchEngine": "DuckDuckGo", "historyRetentionDays": 90,
            "appearance": "System"
        ])
    }
    var body: some Scene {
        WindowGroup("[oasis]", id: "browser", for: BrowserWindowRequest.self) { $request in
            BrowserWindowHost(request: request)
                .tint(Color.oasisAccent)
        } defaultValue: { BrowserWindowRequest() }
        .defaultSize(width: 1240, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.disabled)
        .commands { BrowserCommands() }

        Settings {
            BrowserSettings(library: .shared)
                .tint(Color.oasisAccent)
        }
    }
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browserSession) private var session
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { session?.openNewTabSearch() }.keyboardShortcut("t").disabled(session == nil)
            Button("New Window") { openWindow(value: BrowserWindowRequest()) }.keyboardShortcut("n")
            Button("New Private Window") { openWindow(value: BrowserWindowRequest(isPrivate: true)) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open File…") { session?.openFile() }.keyboardShortcut("o").disabled(session == nil)
            Button("Open Location…") { session?.focusLocation() }.keyboardShortcut("l").disabled(session == nil)
            Divider()
            Button("Close Tab") {
                if let id = session?.selectedID { session?.closeTab(id) }
            }.keyboardShortcut("w").disabled(session == nil)
            Button("Reopen Closed Tab") { session?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(session?.closedTabs.isEmpty ?? true)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Page as Web Archive…") { session?.selectedTab?.saveArchive() }.disabled(session?.selectedTab?.isBlankPage ?? true)
                .keyboardShortcut("s")
            Button("Export Page as PDF…") { session?.selectedTab?.savePDF() }.disabled(session?.selectedTab?.isBlankPage ?? true)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { session?.selectedTab?.printPage() }.keyboardShortcut("p").disabled(session?.selectedTab?.isBlankPage ?? true)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button(ClipboardTyping.shared.isTyping ? "Stop Typing Clipboard" : "Type Clipboard") {
                ClipboardTyping.shared.toggle(spoofModeEnabled: BrowserLibrary.shared.spoofModeEnabled)
            }.keyboardShortcut("9", modifiers: .command)
                .disabled(session == nil || !BrowserLibrary.shared.spoofModeEnabled)
            Button("Find on Page…") { session?.showsFind = true }.keyboardShortcut("f").disabled(session?.selectedTab?.isBlankPage ?? true)
        }
        CommandGroup(after: .toolbar) {
            Button("Open Empty Tab") { session?.newTab() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Reload Page") { session?.selectedTab?.reload() }.keyboardShortcut("r").disabled(session?.selectedTab?.isBlankPage ?? true)
            Button("Stop Loading") { session?.selectedTab?.stop() }.keyboardShortcut(".").disabled(!(session?.selectedTab?.isLoading ?? false))
            Divider()
            Button("Zoom In") { if let tab = session?.selectedTab { tab.setZoom(tab.zoom + 0.1) } }.keyboardShortcut("+")
            Button("Zoom Out") { if let tab = session?.selectedTab { tab.setZoom(tab.zoom - 0.1) } }.keyboardShortcut("-")
            Button("Actual Size") { session?.selectedTab?.setZoom(1) }.keyboardShortcut("0")
            Divider()
            Button("Toggle Reader") { session?.selectedTab?.toggleReader() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session?.selectedTab?.isBlankPage ?? true)
            Button("Show Tabs") { session?.showsTabSidebar = true }.keyboardShortcut("\\", modifiers: [.command, .shift])
            Button("Show Downloads") { session?.showsDownloads.toggle() }.keyboardShortcut("j", modifiers: [.command, .option])
            Divider()
            Button("Next Tab") { session?.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { session?.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("History") {
            Button("Back") { session?.selectedTab?.goBack() }.keyboardShortcut("[").disabled(!(session?.selectedTab?.canGoBack ?? false))
            Button("Forward") { session?.selectedTab?.goForward() }.keyboardShortcut("]").disabled(!(session?.selectedTab?.canGoForward ?? false))
            Divider()
            Button("Show All History") { session?.showLibrary(.history) }.keyboardShortcut("y")
            ForEach(Array((session?.library.history ?? []).prefix(12))) { entry in
                Button(entry.title.isEmpty ? entry.url.displayHost : entry.title) { session?.navigate(to: entry.url) }
            }
        }
        CommandMenu("Bookmarks") {
            Button("Add Bookmark") { session?.bookmarkCurrent() }.keyboardShortcut("d").disabled(session?.selectedTab?.isBlankPage ?? true)
            Button("Add to Reading List") { session?.bookmarkCurrent(readingList: true) }.keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.selectedTab?.isBlankPage ?? true)
            Button("Show Bookmarks") { session?.showLibrary(.bookmarks) }
            Button("Show Reading List") { session?.showLibrary(.readingList) }
            Divider()
            Button("Import Bookmarks…") { BrowserLibrary.shared.importBookmarks() }
            Button("Export Bookmarks…") { BrowserLibrary.shared.exportBookmarks() }
            Divider()
            ForEach(Array(BrowserLibrary.shared.favorites.prefix(15))) { bookmark in
                Button(bookmark.title) { session?.navigate(to: bookmark.url) }
            }
        }
    }
}
