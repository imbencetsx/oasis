import AppKit
import Foundation

/// Spoof Mode feature switches. Mirrors Prism's spoof preferences one to one.
struct SpoofSettings: Codable, Equatable, Hashable, Sendable {
    static let preferenceKey = "spoofSettings"

    var focusVisibility = true
    var fullscreen = true
    var keyboard = true
    var clipboardEvents = true
    var rightClick = true
    var selection = true
    var screenshare = true
    var screenshareCursor = true
    var drm = true
    var osPlatform = true
    var platform = SpoofPlatform.win64
    var browserIdentity = true
    var browser = SpoofBrowser.chrome

    init() {}

    // Missing or unknown values fall back to their defaults, so settings saved by
    // an older or newer version never fail to load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) -> Bool { (try? container.decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } ?? true }
        focusVisibility = flag(.focusVisibility)
        fullscreen = flag(.fullscreen)
        keyboard = flag(.keyboard)
        clipboardEvents = flag(.clipboardEvents)
        rightClick = flag(.rightClick)
        selection = flag(.selection)
        screenshare = flag(.screenshare)
        screenshareCursor = flag(.screenshareCursor)
        drm = flag(.drm)
        osPlatform = flag(.osPlatform)
        browserIdentity = flag(.browserIdentity)
        platform = (try? container.decodeIfPresent(SpoofPlatform.self, forKey: .platform)).flatMap { $0 } ?? .win64
        browser = (try? container.decodeIfPresent(SpoofBrowser.self, forKey: .browser)).flatMap { $0 } ?? .chrome
    }

    static func load(from defaults: UserDefaults = .standard) -> SpoofSettings {
        guard let data = defaults.data(forKey: preferenceKey),
              let settings = try? JSONDecoder().decode(SpoofSettings.self, from: data) else { return SpoofSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preferenceKey) }
    }

    /// The browser identity reported to websites, or nil to keep the engine's own.
    var identity: SpoofIdentity? {
        guard osPlatform || browserIdentity else { return nil }
        return SpoofIdentity(browser: browserIdentity ? browser : .chrome,
                             platform: osPlatform ? platform : .host)
    }
}

enum SpoofPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case win64, linux64, macos64
    var id: String { rawValue }
    static var host: SpoofPlatform { .macos64 }

    var name: String {
        switch self {
        case .win64: "Windows 11 x64"
        case .linux64: "Linux x64"
        case .macos64: "macOS x64"
        }
    }

    fileprivate var token: String {
        switch self {
        case .win64: "Windows NT 10.0; Win64; x64"
        case .linux64: "X11; Linux x86_64"
        case .macos64: "Macintosh; Intel Mac OS X 10_15_7"
        }
    }
    fileprivate var firefoxToken: String {
        switch self {
        case .win64: "Windows NT 10.0; Win64; x64; rv:135.0"
        case .linux64: "X11; Linux x86_64; rv:135.0"
        case .macos64: "Macintosh; Intel Mac OS X 10.15; rv:135.0"
        }
    }
    fileprivate var firefoxAppVersion: String {
        switch self {
        case .win64: "5.0 (Windows)"
        case .linux64: "5.0 (X11)"
        case .macos64: "5.0 (Macintosh)"
        }
    }
    var navigatorPlatform: String {
        switch self {
        case .win64: "Win32"
        case .linux64: "Linux x86_64"
        case .macos64: "MacIntel"
        }
    }
    var clientHintPlatform: String {
        switch self {
        case .win64: "Windows"
        case .linux64: "Linux"
        case .macos64: "macOS"
        }
    }
    var platformVersion: String {
        switch self {
        case .win64: "15.0.0"
        case .linux64: "6.6.0"
        case .macos64: "14.5.0"
        }
    }
}

enum SpoofBrowser: String, Codable, CaseIterable, Identifiable, Sendable {
    case chrome, edge, firefox, safari
    var id: String { rawValue }

    var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .firefox: "Mozilla Firefox"
        case .safari: "Apple Safari"
        }
    }
}

/// A complete, internally consistent browser identity (User-Agent, navigator
/// fields and User-Agent Client Hints).
struct SpoofIdentity: Equatable, Sendable {
    /// Chromium's reduced User-Agent version for the bundled engine.
    static let chromiumMajor = "156"
    static let chromiumVersion = "156.0.0.0"

    let browser: SpoofBrowser
    let platform: SpoofPlatform

    var userAgent: String {
        let chrome = "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(Self.chromiumVersion) Safari/537.36"
        switch browser {
        case .chrome: return "Mozilla/5.0 (\(platform.token)) \(chrome)"
        case .edge: return "Mozilla/5.0 (\(platform.token)) \(chrome) Edg/\(Self.chromiumVersion)"
        case .firefox: return "Mozilla/5.0 (\(platform.firefoxToken)) Gecko/20100101 Firefox/135.0"
        case .safari: return "Mozilla/5.0 (\(platform.token)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
        }
    }

    var appVersion: String {
        browser == .firefox ? platform.firefoxAppVersion : String(userAgent.dropFirst("Mozilla/".count))
    }

    var vendor: String {
        switch browser {
        case .chrome, .edge: "Google Inc."
        case .firefox: ""
        case .safari: "Apple Computer, Inc."
        }
    }

    /// Chromium-based browsers expose navigator.userAgentData, Client Hints and window.chrome.
    var isChromium: Bool { browser == .chrome || browser == .edge }

    var brands: [[String: String]] {
        guard isChromium else { return [] }
        return [["brand": "Chromium", "version": Self.chromiumMajor],
                ["brand": browser == .edge ? "Microsoft Edge" : "Google Chrome", "version": Self.chromiumMajor],
                ["brand": "Not(A:Brand", "version": "24"]]
    }

    var fullVersionList: [[String: String]] {
        guard isChromium else { return [] }
        return [["brand": "Chromium", "version": Self.chromiumVersion],
                ["brand": browser == .edge ? "Microsoft Edge" : "Google Chrome", "version": Self.chromiumVersion],
                ["brand": "Not(A:Brand", "version": "24.0.0.0"]]
    }

    /// EME key systems reported for this browser and operating system.
    var drmKeySystems: [String] {
        switch browser {
        case .chrome, .firefox:
            return ["com.widevine.alpha", "org.w3.clearkey"]
        case .edge:
            if platform == .win64 {
                return ["com.widevine.alpha", "com.microsoft.playready.recommendation",
                        "com.microsoft.playready.recommendation.3000", "com.microsoft.playready", "org.w3.clearkey"]
            }
            return ["com.widevine.alpha", "org.w3.clearkey"]
        case .safari:
            return ["com.apple.fps", "com.apple.fps.1_0", "com.apple.fps.2_0", "com.apple.fps.3_0"]
        }
    }

    /// Parameters for the DevTools User-Agent override.
    var devToolsOverride: [String: Any] {
        var params: [String: Any] = ["userAgent": userAgent, "platform": platform.navigatorPlatform]
        if isChromium {
            params["userAgentMetadata"] = [
                "brands": brands, "fullVersionList": fullVersionList, "fullVersion": Self.chromiumVersion,
                "platform": platform.clientHintPlatform, "platformVersion": platform.platformVersion,
                "architecture": "x86", "model": "", "mobile": false, "bitness": "64", "wow64": false
            ] as [String: Any]
        }
        return params
    }

    /// JSON-safe values consumed by the page script.
    var scriptValue: [String: Any] {
        ["userAgent": userAgent, "appVersion": appVersion, "platform": platform.navigatorPlatform,
         "vendor": vendor, "hasUad": isChromium, "hasChromeObject": isChromium,
         "uadPlatform": platform.clientHintPlatform, "platformVersion": platform.platformVersion,
         "brands": brands, "fullVersionList": fullVersionList, "fullVersion": Self.chromiumVersion]
    }
}

/// The full-screen size Spoof Mode reports, in CSS pixels. Like Prism, this is
/// the real display size of the window's screen, so a page sees what a
/// full-screen browser on this display would report.
@MainActor enum SpoofResolution {
    static func current(for window: NSWindow?) -> CGSize {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let size = screen?.frame.size, size.width >= 2, size.height >= 2 else {
            return CGSize(width: 1920, height: 1080)
        }
        return CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// Aspect-fits the locked resolution into the available page area.
    static func fit(_ resolution: CGSize, in bounds: CGRect) -> (frame: CGRect, scale: CGFloat) {
        guard resolution.width > 0, resolution.height > 0, bounds.width > 0, bounds.height > 0 else { return (bounds, 1) }
        let scale = min(1, bounds.width / resolution.width, bounds.height / resolution.height)
        let width = max(1, (resolution.width * scale).rounded())
        let height = max(1, (resolution.height * scale).rounded())
        let frame = CGRect(x: bounds.minX + ((bounds.width - width) / 2).rounded(),
                           y: bounds.minY + ((bounds.height - height) / 2).rounded(),
                           width: width, height: height)
        return (frame, scale)
    }
}

/// A website Spoof Mode applies to, like a Prism site rule. A selected
/// top-level website includes its embedded frames.
struct SpoofSite: Codable, Hashable, Identifiable, Sendable {
    static let preferenceKey = "spoofSites"

    var host: String
    var includeSubdomains = false
    var id: String { host }

    func matches(host other: String) -> Bool {
        other == host || (includeSubdomains && other.hasSuffix("." + host))
    }

    /// The rule host for a web address: lowercase, without a trailing dot.
    static func host(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    /// Accepts a hostname or a pasted address.
    static func normalized(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let url = text.contains("://") ? URL(string: text) : URL(string: "https://" + text)
        guard let host = host(of: url), host.contains(".") || host == "localhost",
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" }) else { return nil }
        return host
    }

    static func load(from defaults: UserDefaults = .standard) -> [SpoofSite] {
        guard let data = defaults.data(forKey: preferenceKey),
              let sites = try? JSONDecoder().decode([SpoofSite].self, from: data) else { return [] }
        return sites
    }

    static func save(_ sites: [SpoofSite], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(sites) { defaults.set(data, forKey: preferenceKey) }
    }
}
