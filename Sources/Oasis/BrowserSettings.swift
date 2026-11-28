import SwiftUI
import AppKit

struct BrowserSettings: View {
    let library: BrowserLibrary
    @AppStorage(SettingsSection.preferenceKey) private var selection = SettingsSection.general
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
            Tab("Spoof Mode", systemImage: "theatermasks", value: SettingsSection.spoof) {
                SpoofSettingsPage(library: library)
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

enum SettingsSection: String, Hashable {
    case general, appearance, privacy, spoof, typing, advanced
    /// Lets other views open Settings at a particular tab.
    static let preferenceKey = "settingsSection"

    var contentHeight: CGFloat {
        switch self {
        case .general: 260
        case .appearance: 320
        case .privacy: 420
        case .spoof: 640
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
            case .spoof: EmptyView()
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
                LabeledContent("Spoof Mode", value: library.spoofSites.isEmpty ? "No websites" :
                    library.spoofSites.count == 1 ? "1 website" : "\(library.spoofSites.count) websites")
            } header: { Text("Activity privacy") } footer: {
                Text("Spoof Mode is turned on per website with the theater-masks button. Manage websites and features in the Spoof Mode tab.")
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
                LabeledContent("Web engine", value: "Chromium (CEF 156)")
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

/// Spoof Mode preferences. Each switch matches one Prism spoof feature and
/// applies immediately to open tabs while Spoof Mode is on.
private struct SpoofSettingsPage: View {
    @Bindable var library: BrowserLibrary
    @State private var newSite = ""
    @State private var newSiteSubdomains = false

    var body: some View {
        Form {
            Section {
                if library.spoofSites.isEmpty {
                    Text("No websites yet. Open a website and click the theater-masks button, or add one here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.spoofSites) { site in
                    HStack {
                        Text(site.host).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Toggle("Subdomains", isOn: Binding(
                            get: { site.includeSubdomains },
                            set: { value in
                                if let index = library.spoofSites.firstIndex(where: { $0.host == site.host }) {
                                    library.spoofSites[index].includeSubdomains = value
                                }
                            }))
                        .toggleStyle(.checkbox)
                        Button("Remove", systemImage: "minus.circle") {
                            library.spoofSites.removeAll { $0.host == site.host }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Turn Spoof Mode off for \(site.host)")
                    }
                }
                HStack {
                    TextField("Add a website", text: $newSite, prompt: Text("example.com"))
                        .labelsHidden()
                        .onSubmit(addSite)
                    Toggle("Subdomains", isOn: $newSiteSubdomains).toggleStyle(.checkbox)
                    Button("Add", action: addSite).disabled(SpoofSite.normalized(newSite) == nil)
                }
            } header: { Text("Websites") } footer: {
                Text("Spoof Mode applies only to these websites and their embedded frames. Pages reload when a website is added or removed.")
            }
            Section("Spoof mode features") {
                feature("Focus & document visibility",
                        "Report active, focused, and visible document state to defeat tab-switch detection.",
                        \.focusVisibility)
                feature("Fullscreen lock & notification suppression",
                        "Locks the reported resolution to your display's full-screen size, reports true fullscreen mode, and hides exit/re-enter events from websites.",
                        \.fullscreen)
                feature("Selective keyboard listener filtering",
                        "Allow typing characters in textboxes while blocking shortcuts and key listeners.",
                        \.keyboard)
                feature("Clipboard event protection",
                        "Hides copy, cut, and paste events from page scripts to prevent detection.",
                        \.clipboardEvents)
                feature("Force enable right-click context menu",
                        "Bypasses website contextmenu blocks and preventDefault restrictions.",
                        \.rightClick)
                feature("Text selection protection",
                        "Relaxes user-select:none and reports clean selection read APIs.",
                        \.selection)
                feature("Screenshare surface spoofing",
                        "Intercepts screenshare displaySurface settings and labels. Choose to report a full screen or a single tab when sharing.",
                        \.screenshare)
                feature("Screenshare cursor containment",
                        "Keeps the cursor inside tab-only screenshares by parking it near the edge (~1cm) when moving outside.",
                        \.screenshareCursor)
                feature("DRM capability spoofing",
                        "Reports MediaKeySystemAccess (Widevine, PlayReady, FairPlay) matching the spoofed browser and OS.",
                        \.drm)
            }
            Section("Identity") {
                feature("OS & platform spoofing",
                        "Report browser as running on the selected operating system.",
                        \.osPlatform)
                Picker("Spoofed Operating System", selection: $library.spoofSettings.platform) {
                    ForEach(SpoofPlatform.allCases) { platform in
                        Text(platform == .win64 ? "\(platform.name) (Default)" : platform.name).tag(platform)
                    }
                }
                .disabled(!library.spoofSettings.osPlatform)
                feature("Browser identity spoofing",
                        "Report browser identity, User-Agent, and Client Hints as the selected web browser.",
                        \.browserIdentity)
                Picker("Spoofed Web Browser", selection: $library.spoofSettings.browser) {
                    ForEach(SpoofBrowser.allCases) { browser in
                        Text(browser == .chrome ? "\(browser.name) (Default)" : browser.name).tag(browser)
                    }
                }
                .disabled(!library.spoofSettings.browserIdentity)
            }
            Section {
                LabeledContent {
                    Button("Restore Defaults") { library.spoofSettings = SpoofSettings() }
                        .disabled(library.spoofSettings == SpoofSettings())
                } label: {
                    SettingsLabel("Defaults", detail: "Every feature on, Chrome on Windows 11.")
                }
            } footer: {
                Text("These overrides are best effort. Sites can still observe other activity signals; Spoof Mode cannot guarantee that switching tabs or windows is undetectable.")
            }
        }
        .formStyle(.grouped)
    }

    private func addSite() {
        guard let host = SpoofSite.normalized(newSite) else { return }
        if let index = library.spoofSites.firstIndex(where: { $0.host == host }) {
            library.spoofSites[index].includeSubdomains = newSiteSubdomains
        } else {
            library.spoofSites.append(SpoofSite(host: host, includeSubdomains: newSiteSubdomains))
        }
        newSite = ""
        newSiteSubdomains = false
    }

    private func feature(_ title: LocalizedStringResource, _ detail: LocalizedStringResource,
                         _ keyPath: WritableKeyPath<SpoofSettings, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { library.spoofSettings[keyPath: keyPath] },
            set: { library.spoofSettings[keyPath: keyPath] = $0 }
        )) {
            SettingsLabel(title, detail: detail)
        }
    }
}
