import AppKit
import CefKit
import SwiftUI

/// Chromium's native view and page services. The SwiftUI browser shell owns tabs.
@MainActor final class ChromiumTabEngine: NSObject, CefBrowserDelegate {
    weak var tab: BrowserTab?
    let profile: CefProfile
    let host = ChromiumPageHost()
    private(set) var browser: CefBrowser?
    var requestedURL = URL(string: "about:blank")!
    private var ready = false
    private var closed = false
    private var spoofEnabled: Bool
    private var scriptID: String?
    private var configurationTask: Task<Void, Never>?
    private var mainFrameID = ""
    private var mainContexts: Set<Int> = []
    private var certificateFailedURL: URL?
    private(set) var captureWindow: NSWindow?
    private var historyEntries: [ChromiumHistoryEntry] = []
    private var historyIndex = 0
    lazy var sharing = ChromiumTabSharing(engine: self)

    init(tab: BrowserTab, profile: CefProfile, spoofEnabled: Bool) {
        self.tab = tab; self.profile = profile; self.spoofEnabled = spoofEnabled
        super.init()
        host.engine = self
    }

    var backHistory: [ChromiumHistoryEntry] { Array(historyEntries.prefix(historyIndex).reversed()) }

    func attach() {
        guard browser == nil, !closed, host.window != nil else { return }
        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        options.profile = profile
        options.backgroundColor = NSColor.windowBackgroundColor
        let startURL = requestedURL.absoluteString != "about:blank" ? requestedURL : URL(string: "about:blank")!
        let browser = CefBrowser.createBrowser(parentView: host, bounds: host.pageBounds,
            url: startURL, options: options, delegate: self)
        self.browser = browser
        browser.setAccessibilityEnabled(true)
        host.layoutSubtreeIfNeeded()
        browser.observeDevTools { [weak self] method, params in self?.event(method, params: params) }
        configurationTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await browser.devTools("Page.enable")
                let tree = try await browser.devTools("Page.getFrameTree")
                mainFrameID = ((tree["frameTree"] as? [String: Any])?["frame"] as? [String: Any])?["id"] as? String ?? ""
                _ = try await browser.devTools("Runtime.addBinding", params: ["name": "__oasisShareRequest"])
                _ = try await browser.devTools("Runtime.enable")
                try await configureSpoof()
                guard !closed else { return }
                ready = true
                if startURL.absoluteString == "about:blank", requestedURL.absoluteString != "about:blank" {
                    browser.load(requestedURL)
                }
            } catch { tab?.errorMessage = error.localizedDescription }
        }
    }

    func load(_ url: URL) {
        certificateFailedURL = nil
        requestedURL = url
        sharing.stop()
        if ready { browser?.load(url) }
    }

    func setSpoof(_ enabled: Bool) {
        spoofEnabled = enabled
        if !enabled { sharing.stop() }
        guard ready else { return }
        configurationTask?.cancel()
        configurationTask = Task { [weak self] in
            do { try await self?.configureSpoof() }
            catch { self?.tab?.session?.notice = error.localizedDescription }
        }
    }
    func waitForConfiguration() async { await configurationTask?.value }

    private func configureSpoof() async throws {
        guard let browser else { return }
        if let scriptID {
            _ = try await browser.devTools("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": scriptID])
            self.scriptID = nil
        }
        _ = try await evaluate(SpoofMode.restoreSource)
        var identity: [String: Any] = ["userAgent": spoofEnabled ? SpoofMode.userAgent : ""]
        if spoofEnabled {
            identity["platform"] = "Win32"
            identity["userAgentMetadata"] = [
                "brands": [["brand": "Chromium", "version": "156"], ["brand": "Google Chrome", "version": "156"]],
                "fullVersionList": [["brand": "Chromium", "version": "156.0.0.0"], ["brand": "Google Chrome", "version": "156.0.0.0"]],
                "fullVersion": "156.0.0.0", "platform": "Windows", "platformVersion": "10.0.0",
                "architecture": "x86", "model": "", "mobile": false, "bitness": "64", "wow64": false
            ]
        }
        _ = try await browser.devTools("Network.setUserAgentOverride", params: identity)
        if spoofEnabled {
            let script = Self.shareBridge + "\n" + SpoofMode.source
            let result = try await browser.devTools("Page.addScriptToEvaluateOnNewDocument", params: ["source": script, "runImmediately": true])
            scriptID = result["identifier"] as? String
        }
    }

    func evaluate(_ expression: String, contextID: Int? = nil) async throws -> Any? {
        guard let browser else { throw failure("The Chromium page is not ready.") }
        var params: [String: Any] = ["expression": expression, "awaitPromise": true, "returnByValue": true]
        if let contextID { params["contextId"] = contextID }
        let result = try await browser.devTools("Runtime.evaluate", params: params)
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw failure(exception["text"] as? String ?? "Page script failed.")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    func execute(_ script: String) { Task { [weak self] in _ = try? await self?.evaluate(script) } }

    func evaluateIsolated(_ body: String, token: String) async throws -> Any? {
        guard let browser else { return nil }
        let result = try await browser.devTools("Page.createIsolatedWorld", params: ["frameId": mainFrameID, "worldName": "OasisClipboard"])
        guard let context = result["executionContextId"] as? Int else { return nil }
        let encoded = try JSONSerialization.data(withJSONObject: [token])
        let argument = String(decoding: encoded, as: UTF8.self)
        return try await evaluate("((token) => { \(body) })(...\(argument))", contextID: context)
    }

    private func event(_ method: String, params: [String: Any]) {
        switch method {
        case "Page.screencastFrame": sharing.receiveScreencastFrame(params)
        case "Runtime.executionContextCreated":
            guard let context = params["context"] as? [String: Any], let id = context["id"] as? Int,
                  let auxiliary = context["auxData"] as? [String: Any], auxiliary["isDefault"] as? Bool == true,
                  auxiliary["frameId"] as? String == mainFrameID else { return }
            mainContexts.insert(id)
        case "Runtime.executionContextDestroyed":
            if let id = params["executionContextId"] as? Int { mainContexts.remove(id) }
        case "Runtime.executionContextsCleared": mainContexts.removeAll()
        case "Page.frameNavigated":
            guard let frame = params["frame"] as? [String: Any], frame["parentId"] == nil else { return }
            mainFrameID = frame["id"] as? String ?? mainFrameID
            sharing.stop()
        case "Runtime.bindingCalled":
            guard params["name"] as? String == "__oasisShareRequest", let context = params["executionContextId"] as? Int,
                  mainContexts.contains(context), let payload = params["payload"] as? String,
                  let data = payload.data(using: .utf8), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = body["id"] as? String, let request = body["request"] as? [String: String] else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let value = try await sharing.receive(request, enabled: spoofEnabled)
                    reply(id, value: value, error: nil, context: context)
                } catch {
                    reply(id, value: NSNull(), error: error.localizedDescription, context: context)
                }
            }
        default: break
        }
    }

    private func reply(_ id: String, value: Any, error: String?, context: Int) {
        guard mainContexts.contains(context) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: [id, value, error as Any? ?? NSNull()]),
              let json = String(data: data, encoding: .utf8) else { return }
        execute("window.__oasisShareReply?.(...\(json))")
    }

    func close() {
        closed = true; sharing.stop(); configurationTask?.cancel()
        prepareForDisplay()
        browser?.close(force: true); browser = nil
    }

    func prepareForDisplay() {
        guard let captureWindow else { return }
        if captureWindow.contentView === host {
            host.removeFromSuperview(); captureWindow.contentView = nil
        }
        captureWindow.close(); self.captureWindow = nil
    }

    func prepareCaptureSurface() async throws {
        guard let browser else { throw failure("The Chromium page is closed.") }
        guard tab?.session?.selectedID != tab?.id else { return }
        if host.window == nil {
            let size = host.lastVisibleSize
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            window.hasShadow = false
            window.tabbingMode = .disallowed
            host.frame = CGRect(origin: .zero, size: size)
            window.contentView = host
            captureWindow = window
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            browser.wasHidden(false)
            _ = try? await browser.devTools("Page.setWebLifecycleState", params: ["state": "active"])
        }
    }

    func capturePage(format: String = "jpeg", quality: Int = 80) async throws -> [String: Any] {
        try await prepareCaptureSurface()
        guard let browser else { throw failure("The Chromium page is closed.") }
        var params: [String: Any] = ["format": format, "fromSurface": true, "captureBeyondViewport": false]
        if format == "jpeg" { params["quality"] = quality }
        return try await browser.devTools("Page.captureScreenshot", params: params)
    }

    func beginCaptureViewport() async throws -> CGSize {
        guard let browser,
              let viewport = try await evaluate("({width:innerWidth,height:innerHeight,scale:devicePixelRatio})") as? [String: Double],
              let width = viewport["width"], let height = viewport["height"], width >= 2, height >= 2 else {
            throw failure("The shared page is not ready.")
        }
        _ = try await browser.devTools("Emulation.setDeviceMetricsOverride", params: [
            "width": Int(width), "height": Int(height), "deviceScaleFactor": viewport["scale"] ?? 1,
            "mobile": false, "screenWidth": Int(width), "screenHeight": Int(height)
        ])
        return CGSize(width: width, height: height)
    }

    func endCaptureViewport() async {
        _ = try? await browser?.devTools("Emulation.clearDeviceMetricsOverride")
    }

    func refreshHistory() {
        Task { [weak self] in
            guard let self, let browser,
                  let result = try? await browser.devTools("Page.getNavigationHistory") else { return }
            historyIndex = result["currentIndex"] as? Int ?? 0
            historyEntries = (result["entries"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["id"] as? Int, let value = entry["url"] as? String, let url = URL(string: value) else { return nil }
                return ChromiumHistoryEntry(id: id, url: url, title: entry["title"] as? String ?? url.displayHost)
            }
        }
    }

    func go(to entry: ChromiumHistoryEntry) {
        Task { [weak self] in _ = try? await self?.browser?.devTools("Page.navigateToHistoryEntry", params: ["entryId": entry.id]) }
    }

    func browser(_ b: CefBrowser, didChangeTitle title: String) {
        guard ready else { return }
        tab?.title = title.isEmpty ? b.url?.displayHost ?? "Empty Tab" : title
    }
    func browser(_ b: CefBrowser, didChangeURL url: URL?) {
        guard ready else { return }
        if url?.absoluteString == "about:blank", requestedURL.absoluteString != "about:blank" { return }
        tab?.url = url; tab?.isBlankPage = url == nil || url?.absoluteString == "about:blank"
        tab?.session?.save()
    }
    func browser(_ b: CefBrowser, didChangeProgress progress: Double) { tab?.progress = progress }
    func browser(_ b: CefBrowser, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard ready else { return }
        tab?.isLoading = loading; tab?.canGoBack = canGoBack; tab?.canGoForward = canGoForward
        if loading { tab?.errorMessage = nil }
        else if ready {
            tab?.progress = 1
            refreshHistory()
            if let tab, !tab.isPrivate, let url = tab.url, url.isWebURL { tab.session?.library.recordVisit(url: url, title: tab.title) }
            Task { [weak self] in
                await self?.refreshPageColor()
                self?.host.needsDisplay = true
            }
            NSAccessibility.post(element: host, notification: .layoutChanged)
        }
    }
    func browser(_ b: CefBrowser, didChangeFavicon urls: [URL]) {
        guard let url = urls.first, url.isWebURL else { return }
        Task { [weak self] in
            let image = await FaviconLoader.download(url)
            self?.tab?.favicon = image
            if let image, let page = self?.tab?.url { self?.tab?.session?.library.storeFavicon(image, for: page) }
        }
    }
    func browser(_ b: CefBrowser, didFailLoad code: Int, errorText: String, failedURL: String) {
        guard code != -3 else { return }
        if let url = URL(string: failedURL) {
            tab?.url = url
            tab?.isBlankPage = false
        }
        if (-299 ... -200).contains(code) {
            tab?.errorMessage = "The certificate for this server is invalid (\(errorText.isEmpty ? "Certificate Error" : errorText))."
        } else {
            tab?.errorMessage = errorText
        }
        tab?.isLoading = false
    }
    func browser(_ b: CefBrowser, didEncounterCertificateError url: URL?, errorCode: Int) -> Bool {
        if let host = url?.host, host == "localhost" || host == "127.0.0.1" || host == "::1" {
            certificateFailedURL = nil
            return true
        }
        certificateFailedURL = url
        if let url { tab?.url = url; tab?.isBlankPage = false }
        return false
    }
    func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        guard let url = request.targetURL else { return .deny }
        tab?.session?.newTab(url: url, select: request.disposition != .newBackgroundTab, spaceID: tab?.spaceID)
        return .handled
    }
    func browser(_ b: CefBrowser, didRequestNewTab url: URL?) -> Bool {
        guard let url else { return false }
        tab?.session?.newTab(url: url, spaceID: tab?.spaceID); return true
    }
    func browser(_ b: CefBrowser, didChangeFullscreen fullscreen: Bool) {
        guard !spoofEnabled, let window = host.window, window.styleMask.contains(.fullScreen) != fullscreen else { return }
        window.toggleFullScreen(nil)
    }
    func browser(_ b: CefBrowser, handleKeyEvent event: CefKeyEvent, isBeforePage: Bool) -> Bool {
        guard isBeforePage, event.hasCommand,
              event.phase == .rawKeyDown || event.phase == .keyDown,
              let native = NSApp.currentEvent else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: native) ?? false
    }
    func browser(_ b: CefBrowser, decidePolicyForNavigation url: URL?, isRedirect: Bool, userGesture: Bool) -> CefNavigationDecision {
        guard let url else { return .cancel }
        if ["http", "https", "about", "file", "data", "blob", "chrome", "chrome-error"].contains(url.scheme?.lowercased() ?? "") { return .allow }
        if userGesture {
            let alert = NSAlert()
            alert.messageText = "Open another app?"
            alert.informativeText = "This link wants to open \(url.scheme ?? "another app"): in another application."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Open App")
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
        }
        return .cancel
    }
    func browser(_ b: CefBrowser, didReceiveAuthChallenge challenge: CefAuthChallenge, callback: CefAuthCallback) -> Bool {
        guard let window = host.window, window.attachedSheet == nil else { return false }
        let user = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        user.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        fields.addSubview(user); fields.addSubview(password)
        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.host)"
        alert.addButton(withTitle: "Sign In"); alert.addButton(withTitle: "Cancel"); alert.accessoryView = fields
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { callback.continue(username: user.stringValue, password: password.stringValue) }
            else { callback.cancel() }
        }
        return true
    }
    func browserDidClose(_ b: CefBrowser) {
        sharing.stop()
        if !closed, !CefRuntime.shared.isTerminationRequested, let tab { tab.session?.closeTab(tab.id) }
    }
    func browser(_ b: CefBrowser, requestsPermission request: CefPermissionRequest) -> CefPermissionDecision {
        let resources: [(CefPermissionKind, String)] = [
            (.camera, "camera"), (.microphone, "microphone"), (.geolocation, "location"),
            (.notifications, "notifications"), (.clipboard, "clipboard"), (.midi, "MIDI devices"),
            (.pointerLock, "pointer lock"), (.storageAccess, "website storage"),
            (.sensors, "sensors"), (.windowManagement, "window management"), (.downloads, "downloads")
        ]
        let names = resources.filter { request.kinds.contains($0.0) }.map(\.1)
        let alert = NSAlert()
        alert.messageText = "Allow \(request.origin) to use \(names.isEmpty ? "the requested features" : names.joined(separator: " and "))?"
        alert.addButton(withTitle: "Don't Allow"); alert.addButton(withTitle: "Allow")
        return alert.runModal() == .alertSecondButtonReturn ? .allow : .deny
    }
    func browser(_ b: CefBrowser, decidePolicyForDownload download: CefDownload, suggestedName: String) -> CefDownloadDecision {
        guard let downloads = tab?.session?.downloads else { return .deny }
        let decision = downloads.receiveChromium(download, suggestedName: suggestedName)
        downloads.items.first(where: { $0.chromiumID == download.id })?.chromiumCancel = { [weak b] in b?.cancelDownload(download.id) }
        return decision
    }
    func browser(_ b: CefBrowser, downloadDidProgress download: CefDownload) { tab?.session?.downloads.updateChromium(download) }
    func browser(_ b: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason, errorCode: Int) {
        tab?.errorMessage = "The webpage stopped responding. Reload it to continue."; tab?.isLoading = false
    }

    private func refreshPageColor() async {
        guard let value = try? await evaluate("""
            (() => {
              for (const element of [document.body, document.documentElement]) {
                if (!element) continue;
                const color = getComputedStyle(element).backgroundColor;
                if (color !== 'transparent' && color !== 'rgba(0, 0, 0, 0)') return color;
              }
              return matchMedia('(prefers-color-scheme: dark)').matches ? 'rgb(24, 24, 24)' : 'rgb(255, 255, 255)';
            })()
            """),
              let string = value as? String else { return }
        let components = string.split(whereSeparator: { !($0.isNumber || $0 == ".") }).compactMap { Double($0) }
        guard components.count >= 3 else { return }
        tab?.chromeColor = NSColor(srgbRed: components[0]/255, green: components[1]/255, blue: components[2]/255, alpha: 1)
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "Oasis.Chromium", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    private static let shareBridge = """
    (() => {
      if (window.__oasisShareReply) return;
      const requests = new Map();
      window.__oasisShareReply = (id, value, error) => {
        const pending = requests.get(id); if (!pending) return;
        requests.delete(id); error ? pending.reject(new Error(error)) : pending.resolve(value);
      };
      const bridge = {postMessage: request => new Promise((resolve, reject) => {
        const id = crypto.randomUUID(); requests.set(id, {resolve, reject});
        window.__oasisShareRequest(JSON.stringify({id, request}));
      })};
      window.webkit ??= {}; window.webkit.messageHandlers ??= {};
      window.webkit.messageHandlers.oasisWindowShare = bridge;
    })();
    """
}

struct ChromiumHistoryEntry: Identifiable { let id: Int; let url: URL; let title: String }

@MainActor final class ChromiumPageHost: NSView {
    weak var engine: ChromiumTabEngine?
    private(set) var lastVisibleSize = CGSize(width: 1280, height: 900)
    var topInset: CGFloat = 64 { didSet { needsLayout = true; needsDisplay = true } }
    override var isFlipped: Bool { true }
    var pageBounds: CGRect { CGRect(x: 0, y: topInset, width: bounds.width, height: max(1, bounds.height - topInset)) }
    override func draw(_ dirtyRect: NSRect) {
        let color = engine?.tab?.chromeColor ?? NSColor.windowBackgroundColor
        color.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let browser = engine?.browser, window != nil {
            browser.setAccessibilityEnabled(false)
            browser.setAccessibilityEnabled(true)
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        engine?.attach()
    }
    override func layout() {
        super.layout()
        if window?.isVisible == true, bounds.width >= 2, bounds.height > topInset {
            lastVisibleSize = bounds.size
        }
        if let view = engine?.browser?.nativeView { view.frame = pageBounds }
    }
}
