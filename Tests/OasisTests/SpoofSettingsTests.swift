import Foundation
import Testing
import WebKit
@testable import Oasis

@Suite("Spoof settings", .serialized)
@MainActor struct SpoofSettingsTests {
    @Test func missingAndUnknownValuesFallBackToDefaults() throws {
        let partial = Data(#"{"keyboard": false, "platform": "amiga", "browser": "edge"}"#.utf8)
        let settings = try JSONDecoder().decode(SpoofSettings.self, from: partial)
        #expect(settings.keyboard == false)
        #expect(settings.focusVisibility && settings.fullscreen && settings.clipboardEvents && settings.rightClick)
        #expect(settings.selection && settings.screenshare && settings.screenshareCursor && settings.drm)
        #expect(settings.platform == .win64)
        #expect(settings.browser == .edge)
        let roundTrip = try JSONDecoder().decode(SpoofSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
    }

    @Test func identitiesMatchTheSelectedBrowserAndPlatform() throws {
        var settings = SpoofSettings()
        let chrome = try #require(settings.identity)
        #expect(chrome.userAgent == "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36")
        #expect(chrome.appVersion == String(chrome.userAgent.dropFirst(8)))
        #expect((chrome.devToolsOverride["userAgentMetadata"] as? [String: Any])?["platform"] as? String == "Windows")

        settings.browser = .edge; settings.platform = .linux64
        let edge = try #require(settings.identity)
        #expect(edge.userAgent.hasSuffix("Edg/156.0.0.0") && edge.userAgent.contains("X11; Linux x86_64"))
        #expect(edge.brands.contains { $0["brand"] == "Microsoft Edge" })
        #expect(edge.platform.navigatorPlatform == "Linux x86_64")

        settings.browser = .firefox; settings.platform = .macos64
        let firefox = try #require(settings.identity)
        #expect(firefox.userAgent == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:135.0) Gecko/20100101 Firefox/135.0")
        #expect(firefox.appVersion == "5.0 (Macintosh)" && firefox.vendor.isEmpty)
        #expect(firefox.devToolsOverride["userAgentMetadata"] == nil)

        settings.browser = .safari; settings.platform = .win64
        let safari = try #require(settings.identity)
        #expect(safari.userAgent.contains("Version/18.3 Safari/605.1.15") && safari.vendor == "Apple Computer, Inc.")

        // Each switch falls back independently: the host OS, or Chrome.
        settings.osPlatform = false
        #expect(settings.identity?.platform == .macos64)
        settings.browserIdentity = false
        #expect(settings.identity == nil)
        settings.osPlatform = true
        #expect(settings.identity?.browser == .chrome && settings.identity?.platform == .win64)
    }

    @Test func websiteRulesMatchHostsLikePrism() {
        #expect(SpoofSite.host(of: URL(string: "https://Example.COM./path")) == "example.com")
        #expect(SpoofSite.host(of: URL(string: "about:blank")) == nil)
        #expect(SpoofSite.host(of: URL(string: "file:///tmp/a.html")) == nil)
        #expect(SpoofSite.normalized("  https://exam.example.org/test?q=1 ") == "exam.example.org")
        #expect(SpoofSite.normalized("example.com") == "example.com")
        #expect(SpoofSite.normalized("not a host") == nil)
        let exact = SpoofSite(host: "example.com")
        #expect(exact.matches(host: "example.com") && !exact.matches(host: "www.example.com") && !exact.matches(host: "badexample.com"))
        let wide = SpoofSite(host: "example.com", includeSubdomains: true)
        #expect(wide.matches(host: "a.b.example.com") && !wide.matches(host: "badexample.com"))
    }

    @Test func togglingFollowsTheCurrentWebsite() {
        let saved = UserDefaults.standard.data(forKey: SpoofSite.preferenceKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: SpoofSite.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: SpoofSite.preferenceKey) }
        }
        let library = BrowserLibrary(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Library.json"))
        library.spoofSites = []
        let page = URL(string: "https://quiz.example.com/test")!
        #expect(library.toggleSpoof(for: page) == nil)
        #expect(library.isSpoofed(page) && !library.isSpoofed(URL(string: "https://example.com")!))
        #expect(library.spoofSites == [SpoofSite(host: "quiz.example.com")])
        #expect(library.toggleSpoof(for: page) == nil)
        #expect(!library.isSpoofed(page) && library.spoofSites.isEmpty)
        // A website covered by a parent rule is changed in Settings, not by the toggle.
        library.spoofSites = [SpoofSite(host: "example.com", includeSubdomains: true)]
        #expect(library.isSpoofed(page))
        #expect(library.toggleSpoof(for: page) != nil)
        #expect(library.isSpoofed(page))
        #expect(library.toggleSpoof(for: URL(string: "about:blank")) != nil)
        library.spoofSites = []
    }

    @Test func lockedResolutionLetterboxesIntoTheAvailableArea() {
        let fit = SpoofResolution.fit(CGSize(width: 1920, height: 1080), in: CGRect(x: 0, y: 64, width: 960, height: 800))
        #expect(fit.scale == 0.5)
        #expect(fit.frame == CGRect(x: 0, y: 194, width: 960, height: 540))
        let large = SpoofResolution.fit(CGSize(width: 1280, height: 800), in: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        #expect(large.scale == 1 && large.frame.size == CGSize(width: 1280, height: 800))
    }

    private func loadedTab(_ settings: SpoofSettings) async throws -> BrowserTab {
        let tab = BrowserTab(isPrivate: true, spoofModeEnabled: true, spoofSettings: settings)
        tab.webView.loadHTMLString("<title>Settings</title><p id='text'>Selectable text</p><input id='field' value='Hello world'>",
                                   baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if tab.webView.title == "Settings" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(tab.webView.title == "Settings")
        return tab
    }

    @Test func featureSwitchesApplyLiveToTheOpenPage() async throws {
        let tab = try await loadedTab(SpoofSettings())
        defer { tab.close() }
        let probe = """
            (() => { const range = document.createRange(); range.selectNodeContents(text);
              getSelection().removeAllRanges(); getSelection().addRange(range);
              field.setSelectionRange(2, 5);
              const state = {selection: getSelection().toString(), ranges: getSelection().rangeCount,
                start: field.selectionStart, end: field.selectionEnd,
                hidden: document.hidden, focus: document.hasFocus(), fullscreen: !!document.fullscreenElement,
                ua: navigator.userAgent, vendor: navigator.vendor, uad: navigator.userAgentData === undefined ? 'none' : 'present'};
              getSelection().removeAllRanges(); return JSON.stringify(state); })()
            """
        func state() async throws -> [String: Any] {
            let json = try #require(try await tab.webView.evaluateJavaScript(probe) as? String)
            return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        }
        var current = try await state()
        #expect(current["selection"] as? String == "" && current["ranges"] as? Int == 0)
        #expect(current["start"] as? Int == 0 && current["end"] as? Int == 0)
        #expect(current["fullscreen"] as? Bool == true && current["hidden"] as? Bool == false)
        #expect(current["uad"] as? String == "present")

        var settings = SpoofSettings()
        settings.selection = false
        settings.fullscreen = false
        settings.browser = .firefox
        tab.setSpoofMode(true, settings: settings)
        #expect(tab.webView.customUserAgent == settings.identity?.userAgent)
        current = try await state()
        #expect(current["selection"] as? String == "Selectable text" && current["ranges"] as? Int == 1)
        #expect(current["start"] as? Int == 2 && current["end"] as? Int == 5)
        #expect(current["fullscreen"] as? Bool == false && current["hidden"] as? Bool == false)
        #expect((current["ua"] as? String)?.contains("Firefox/135.0") == true)
        #expect(current["vendor"] as? String == "" && current["uad"] as? String == "none")

        settings.osPlatform = false
        settings.browserIdentity = false
        tab.setSpoofMode(true, settings: settings)
        #expect(tab.webView.customUserAgent?.isEmpty ?? true)
        current = try await state()
        #expect((current["ua"] as? String)?.contains("Firefox") == false)
        #expect((current["ua"] as? String)?.contains("Windows") == false)
    }

    @Test func scriptEventsStillReachThePageButFilteredOnesCanBeDisabled() async throws {
        let tab = try await loadedTab(SpoofSettings())
        defer { tab.close() }
        // Script-dispatched keyboard, clipboard and context-menu events are not
        // user activity, so they reach listeners. Window focus never does.
        let script = """
            (() => { let keys = 0, clipboard = 0, menu = 0, focus = 0;
              const k = () => keys++, c = () => clipboard++, m = () => menu++, f = () => focus++;
              addEventListener('keydown', k); addEventListener('copy', c); addEventListener('contextmenu', m); addEventListener('focus', f);
              field.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
              field.dispatchEvent(new Event('copy', {bubbles: true}));
              field.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true}));
              dispatchEvent(new Event('focus'));
              removeEventListener('keydown', k); removeEventListener('copy', c); removeEventListener('contextmenu', m); removeEventListener('focus', f);
              return [keys, clipboard, menu, focus].join(','); })()
            """
        #expect(try await tab.webView.evaluateJavaScript(script) as? String == "1,1,1,0")
        var settings = SpoofSettings()
        settings.focusVisibility = false
        tab.setSpoofMode(true, settings: settings)
        #expect(try await tab.webView.evaluateJavaScript(script) as? String == "1,1,1,1")
        #expect(try await tab.webView.evaluateJavaScript("Object.hasOwn(document, 'hidden')") as? Bool == false)
    }

    @Test func drmSpoofingMatchesBrowserAndPlatform() async throws {
        var settings = SpoofSettings()
        #expect(settings.identity?.drmKeySystems == ["com.widevine.alpha", "org.w3.clearkey"])
        settings.browser = .edge
        #expect(settings.identity?.drmKeySystems.contains("com.microsoft.playready.recommendation") == true)
        settings.platform = .macos64
        #expect(settings.identity?.drmKeySystems == ["com.widevine.alpha", "org.w3.clearkey"])
        settings.browser = .safari
        #expect(settings.identity?.drmKeySystems.contains("com.apple.fps") == true)

        let tab = try await loadedTab(SpoofSettings())
        defer { tab.close() }
        let probe = """
            const probe = async (system) => {
              try {
                const access = await navigator.requestMediaKeySystemAccess(system, [{
                  initDataTypes: ['cenc'],
                  videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }]
                }]);
                const cfg = access.getConfiguration();
                const keys = await access.createMediaKeys();
                const session = keys.createSession();
                const msg = await new Promise(resolve => {
                  session.addEventListener('message', e => resolve(e.messageType));
                  session.generateRequest('cenc', new Uint8Array([1, 2, 3, 4]));
                });
                await new Promise(resolve => {
                  session.onkeystatuseschange = () => resolve();
                  session.update(new Uint8Array([5, 6]));
                });
                const status = Array.from(session.keyStatuses.values())[0];
                await session.close();
                return access.keySystem + ':' + cfg.videoCapabilities.length + ':' + msg + ':' + status + ':' + (session.sessionId.length > 0);
              } catch (e) {
                return 'ERR:' + e.name;
              }
            };
            return JSON.stringify({
              widevine: await probe('com.widevine.alpha'),
              playready: await probe('com.microsoft.playready.recommendation'),
              fairplay: await probe('com.apple.fps')
            });
            """
        func runProbe() async throws -> [String: String] {
            let json = try #require(try await tab.webView.callAsyncJavaScript(probe, contentWorld: .page) as? String)
            return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        }

        var result = try await runProbe()
        #expect(result["widevine"] == "com.widevine.alpha:1:license-request:usable:true")
        #expect(result["playready"] == "ERR:NotSupportedError")
        #expect(result["fairplay"] == "ERR:NotSupportedError")

        var edgeWin = SpoofSettings()
        edgeWin.browser = .edge
        edgeWin.platform = .win64
        tab.setSpoofMode(true, settings: edgeWin)
        result = try await runProbe()
        #expect(result["widevine"] == "com.widevine.alpha:1:license-request:usable:true")
        #expect(result["playready"] == "com.microsoft.playready.recommendation:1:license-request:usable:true")

        var safariMac = SpoofSettings()
        safariMac.browser = .safari
        safariMac.platform = .macos64
        tab.setSpoofMode(true, settings: safariMac)
        result = try await runProbe()
        #expect(result["widevine"] == "ERR:NotSupportedError")
        #expect(result["fairplay"] == "com.apple.fps:1:license-request:usable:true")
    }
}
