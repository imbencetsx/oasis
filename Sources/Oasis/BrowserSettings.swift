import SwiftUI
import AppKit

struct BrowserSettings: View {
    let library: BrowserLibrary
    @State private var selection = SettingsSection.general
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        TabView(selection: $selection) {
            Tab("General", systemImage: "gearshape", value: SettingsSection.general) {
                BrowserSettingsPage(section: .general, library: library)
            }
            Tab("Appearance", systemImage: "paintpalette", value: SettingsSection.appearance) {
                BrowserSettingsPage(section: .appearance, library: library)
            }
            Tab("Privacy", systemImage: "hand.raised", value: SettingsSection.privacy) {
                BrowserSettingsPage(section: .privacy, library: library)
            }
            Tab("Typing", systemImage: "keyboard", value: SettingsSection.typing) {
                BrowserSettingsPage(section: .typing, library: library)
            }
            Tab("Advanced", systemImage: "gearshape.2", value: SettingsSection.advanced) {
                BrowserSettingsPage(section: .advanced, library: library)
            }
        }
        .frame(width: 580, height: selection.contentHeight)
        .preferredColorScheme(appearance == "System" ? nil : appearance == "Dark" ? .dark : .light)
    }
}

private enum SettingsSection: Hashable {
    case general, appearance, privacy, typing, advanced

    var contentHeight: CGFloat {
        switch self {
        case .general: 260
        case .appearance: 320
        case .privacy: 500
        case .typing: 340
        case .advanced: 380
        }
    }
}

private struct BrowserSettingsPage: View {
    let section: SettingsSection
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
        Form {
            switch section {
            case .general: general
            case .appearance: appearanceSettings
            case .privacy: privacy
            case .typing: clipboardTyping
            case .advanced: advanced
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove all website data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Remove Website Data", role: .destructive) { Task { await library.clearWebsiteData() } }
        } message: {
            Text("This removes cookies, caches, and site storage. You may need to sign in again.")
        }
        .alert("Default Browser", isPresented: Binding(
            get: { defaultBrowserMessage != nil },
            set: { if !$0 { defaultBrowserMessage = nil } }
        )) {
            Button("OK") { defaultBrowserMessage = nil }
        } message: {
            Text(defaultBrowserMessage ?? "")
        }
    }

    private var general: some View {
        Group {
            Section("Browsing") {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                LabeledContent {
                    Button("Make Default…", action: makeDefaultBrowser)
                        .accessibilityLabel("Make [oasis] the default browser")
                } label: {
                    SettingsLabel("Default browser", detail: "Open links from other apps in [oasis].")
                }
            }
            Section("Startup") {
                Toggle(isOn: $restoreSession) {
                    Text("Restore windows and tabs on launch")
                }
            }
        }
    }

    private var appearanceSettings: some View {
        Group {
            Section("Theme") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)
            }
            Section {
                SettingsSlider(
                    "Background grain", value: Binding(
                        get: { BackgroundGrain.normalized(backgroundGrain) },
                        set: { backgroundGrain = BackgroundGrain.normalized($0) }
                    ), range: 0...1,
                    valueLabel: BackgroundGrain.normalized(backgroundGrain).formatted(.percent.precision(.fractionLength(0))),
                    lowerLabel: "None", upperLabel: "More",
                    isDefault: backgroundGrain == BackgroundGrain.defaultIntensity
                ) { backgroundGrain = BackgroundGrain.defaultIntensity }
            } header: {
                Text("Texture")
            } footer: {
                Text("Adds grain to the translucent background and sidebar. Changes apply immediately.")
            }
        }
    }

    private var privacy: some View {
        Group {
            Section {
                Picker("Keep history", selection: $historyDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Until manually cleared").tag(0)
                }
            } header: { Text("History") } footer: {
                Text("History and bookmarks stay on your Mac. No account or analytics service.")
            }
            Section {
                Toggle("Spoof Mode", isOn: $library.spoofModeEnabled)
                DisclosureGroup("How Spoof Mode works") {
                    Text("Reports pages as visible and focused, and suppresses visibility, window-focus, and pointer enter/leave events. Real clicks, typing, and input-field focus still work. No artificial user activity is generated.")
                    Text("Reload open pages for coverage from document start, including embedded frames. This is best effort: timing, network behavior, and other APIs can still reveal activity. Some hover features may behave differently.")
                }
                .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Activity privacy") } footer: {
                Text("Reload open pages after changing Spoof Mode.")
            }
            Section {
                LabeledContent {
                    Text("⇧⌘N").monospaced().foregroundStyle(.secondary)
                        .accessibilityLabel("Shift Command N")
                } label: {
                    SettingsLabel("Private window", detail: "History and tabs aren’t saved; site data stays in memory.")
                }
            } footer: {
                Text("Bookmarks and downloaded files are retained.")
            }
            Section {
                LabeledContent {
                    Button(library.isClearingWebsiteData ? "Removing…" : "Remove All…", role: .destructive) { confirmClear = true }
                        .disabled(library.isClearingWebsiteData)
                        .accessibilityLabel("Remove all website data")
                } label: {
                    SettingsLabel("Website data", detail: "Remove cookies, caches, and site storage.")
                }
            } footer: {
                Text("Removing website data signs you out of most websites.")
            }
        }
    }

    private var clipboardTyping: some View {
        Group {
            Section {
                LabeledContent {
                    Text("⌘9").monospaced().foregroundStyle(.secondary)
                        .accessibilityLabel("Command 9")
                } label: {
                    SettingsLabel("Type your clipboard", detail: "Press again to stop. Available in Spoof Mode.")
                }
            } header: { Text("Keyboard shortcut") } footer: {
                Text("Focus a text field first. Types text without pressing Return or submitting forms.")
            }
            Section {
                SettingsSlider(
                    "Typing speed", value: Binding(
                        get: { log10(ClipboardTypingSpeed.normalized(typingSpeed)) },
                        set: { typingSpeed = pow(10, $0) }
                    ), range: -1...1, valueLabel: typingSpeedLabel,
                    lowerLabel: "0.1× · Slower", upperLabel: "10× · Faster",
                    isDefault: typingSpeed == ClipboardTypingSpeed.defaultMultiplier
                ) { typingSpeed = ClipboardTypingSpeed.defaultMultiplier }
            } header: { Text("Pace") } footer: {
                Text("Random pauses keep typing natural at every speed. Default: 1×.")
            }
        }
    }

    private var advanced: some View {
        Group {
            Section {
                Toggle("Enable Web Inspector", isOn: $inspector)
            } header: { Text("Developer tools") } footer: {
                Text("Applies to new tabs. Right-click a webpage and choose Inspect Element.")
            }
            Section("Bookmarks") {
                LabeledContent("Import bookmarks") {
                    Button("Choose HTML File…") { library.importBookmarks() }
                }
                LabeledContent("Export bookmarks") {
                    Button("Export HTML…") { library.exportBookmarks() }
                }
            }
            Section("About [oasis]") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Web engine", value: "System WebKit")
            }
        }
    }

    private var typingSpeedLabel: String {
        ClipboardTypingSpeed.normalized(typingSpeed).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func makeDefaultBrowser() {
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

private struct SettingsLabel: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    init(_ title: LocalizedStringResource, detail: LocalizedStringResource) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSlider: View {
    let title: LocalizedStringResource
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueLabel: String
    let lowerLabel: LocalizedStringResource
    let upperLabel: LocalizedStringResource
    let isDefault: Bool
    let reset: () -> Void

    init(_ title: LocalizedStringResource, value: Binding<Double>, range: ClosedRange<Double>,
         valueLabel: String, lowerLabel: LocalizedStringResource, upperLabel: LocalizedStringResource,
         isDefault: Bool, reset: @escaping () -> Void) {
        self.title = title
        self._value = value
        self.range = range
        self.valueLabel = valueLabel
        self.lowerLabel = lowerLabel
        self.upperLabel = upperLabel
        self.isDefault = isDefault
        self.reset = reset
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                Spacer()
                Text(valueLabel).monospacedDigit().foregroundStyle(.secondary)
                Button("Reset to Default", action: reset).disabled(isDefault)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
                .accessibilityLabel(Text(title))
                .accessibilityValue(valueLabel)
            HStack {
                Text(lowerLabel)
                Spacer()
                Text(upperLabel)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}
