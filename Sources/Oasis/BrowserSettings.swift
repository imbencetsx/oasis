import SwiftUI
import WebKit

struct BrowserSettings: View {
    @Bindable var library: BrowserLibrary
    @AppStorage("searchEngine") private var searchEngine = SearchEngine.duckDuckGo.rawValue
    @AppStorage("restoreSession") private var restoreSession = false
    @AppStorage("appearance") private var appearance = "System"
    @AppStorage("historyRetentionDays") private var historyDays = 90
    @AppStorage("enableWebInspector") private var inspector = false
    @AppStorage(ClipboardTypingSpeed.preferenceKey) private var typingSpeed = ClipboardTypingSpeed.defaultMultiplier
    @AppStorage(BackgroundGrain.preferenceKey) private var backgroundGrain = BackgroundGrain.defaultIntensity
    @State private var confirmClear = false
    @State private var defaultBrowserMessage: String?
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Section("Browsing") {
                        Picker("Search engine", selection: $searchEngine) {
                            ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        Toggle("Restore windows and tabs on launch", isOn: $restoreSession)
                        LabeledContent("Default browser") {
                            Button("Make Default…") {
                                NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { error in
                                    Task { @MainActor in
                                        if let error { defaultBrowserMessage = error.localizedDescription }
                                        else {
                                            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "https") { error in
                                                Task { @MainActor in defaultBrowserMessage = error?.localizedDescription ?? "[oasis] is now your default browser." }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Section("Appearance") {
                        Picker("Theme", selection: $appearance) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Background grain")
                                Spacer()
                                Text(BackgroundGrain.normalized(backgroundGrain), format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Button("Reset to Default") { backgroundGrain = BackgroundGrain.defaultIntensity }
                                    .disabled(backgroundGrain == BackgroundGrain.defaultIntensity)
                            }
                            Slider(value: Binding(
                                get: { BackgroundGrain.normalized(backgroundGrain) },
                                set: { backgroundGrain = BackgroundGrain.normalized($0) }
                            ), in: 0...1)
                                .labelsHidden()
                                .accessibilityLabel("Background grain")
                                .accessibilityValue(BackgroundGrain.normalized(backgroundGrain).formatted(.percent.precision(.fractionLength(0))))
                            HStack {
                                Text("None")
                                Spacer()
                                Text("More")
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Adds texture to the translucent background and sidebar. Changes apply immediately.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
            Tab("Privacy", systemImage: "hand.raised") {
                Form {
                    Section("History") {
                        Picker("Keep history", selection: $historyDays) {
                            Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365); Text("Until manually cleared").tag(0)
                        }
                        Text("History and bookmarks are stored locally on your Mac. [oasis] has no account or analytics service.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Website data") {
                        Text("Cookies and caches keep you signed in to websites. Removing them signs you out of most websites.").font(.callout).foregroundStyle(.secondary)
                        Button(library.isClearingWebsiteData ? "Removing Website Data…" : "Remove All Website Data…", role: .destructive) { confirmClear = true }
                            .disabled(library.isClearingWebsiteData)
                    }
                    Section("Activity privacy") {
                        Toggle("Spoof Mode", isOn: $library.spoofModeEnabled)
                        Text("Reports pages as visible and focused and suppresses visibility, window-focus, and mouse/pointer enter/leave events. Real clicks, typing, and input-field focus still work. No artificial user activity is generated.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Reload open pages after changing this setting for coverage from document start, including embedded frames. This is best effort; timing, network behavior, and other APIs can still reveal activity. Some hover features may behave differently.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Private browsing") {
                        Text("Open a private window with ⇧⌘N. Private windows don’t save history or restore tabs, and their website data stays in memory. Bookmarks and downloaded files are retained.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Section("Clipboard typing") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Typing speed")
                                Spacer()
                                Text(typingSpeedLabel).monospacedDigit().foregroundStyle(.secondary)
                                Button("Reset to Default") { typingSpeed = ClipboardTypingSpeed.defaultMultiplier }
                                    .disabled(typingSpeed == ClipboardTypingSpeed.defaultMultiplier)
                            }
                            Slider(value: Binding(
                                get: { log10(ClipboardTypingSpeed.normalized(typingSpeed)) },
                                set: { typingSpeed = pow(10, $0) }
                            ), in: -1...1, step: 0.01)
                                .accessibilityLabel("Clipboard typing speed")
                                .accessibilityValue(typingSpeedLabel)
                            HStack {
                                Text("0.1× · Slower")
                                Spacer()
                                Text("10× · Faster")
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Used by ⌘9 in Spoof Mode. Random pauses stay enabled at every speed. Default: 1×.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
            Tab("Advanced", systemImage: "chevron.left.forwardslash.chevron.right") {
                Form {
                    Section("Developer tools") {
                        Toggle("Enable Web Inspector for new tabs", isOn: $inspector)
                        Text("After enabling, open a new tab and use Inspect Element from a webpage’s context menu.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Bookmarks") {
                        Button("Import Bookmarks from HTML…") { library.importBookmarks() }
                        Button("Export Bookmarks to HTML…") { library.exportBookmarks() }
                    }
                    Section {
                        LabeledContent("Version", value: "1.0")
                        LabeledContent("Web engine", value: "System WebKit")
                        Text("Made for a calmer web.").foregroundStyle(.secondary)
                    } header: {
                        Text("[oasis]").font(.custom("GeistMono-Regular", size: 14))
                    }
                }.formStyle(.grouped)
            }
        }
        .frame(width: 540, height: 460)
        .confirmationDialog("Remove all website data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Remove Website Data", role: .destructive) { Task { await library.clearWebsiteData() } }
        } message: { Text("This removes cookies, caches, and site storage. You may need to sign in again.") }
        .alert("Default Browser", isPresented: Binding(get: { defaultBrowserMessage != nil }, set: { if !$0 { defaultBrowserMessage = nil } })) {
            Button("OK") { defaultBrowserMessage = nil }
        } message: { Text(defaultBrowserMessage ?? "") }
    }

    private var typingSpeedLabel: String {
        ClipboardTypingSpeed.normalized(typingSpeed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
