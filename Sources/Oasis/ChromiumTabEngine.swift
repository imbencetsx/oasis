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
    /// Decides Spoof Mode for a website (the library's site rules).
    var spoofPolicy: (@MainActor (URL?) -> Bool)?
    /// A navigation switched Spoof Mode; check the new document once it loads.
    private var verifyAfterLoad = false
    private var verificationReloadURL: URL?
    private(set) var spoofSettings: SpoofSettings
    private var scriptID: String?
    /// The full-screen resolution the page renders at while the fullscreen lock is on.
    private(set) var lockedResolution: CGSize?
    private var appliedLockScale: CGFloat?
    /// The scale the page has actually been painted at (confirmed after the override).
    private var renderedLockScale: CGFloat?
    private var metricsOverridden = false
    private var captureViewportActive = false
    /// Out-of-process iframe sessions and their installed script identifiers.
    private var frameSessions: [String: String] = [:]
    private var configurationTask: Task<Void, Never>?
    private var mainFrameID = ""
    private var mainContexts: Set<Int> = []
    private var certificateFailedURL: URL?
    private(set) var captureWindow: NSWindow?
    private var historyEntries: [ChromiumHistoryEntry] = []
    private var historyIndex = 0
    lazy var sharing = ChromiumTabSharing(engine: self)

    init(tab: BrowserTab, profile: CefProfile, spoofEnabled: Bool, settings: SpoofSettings = SpoofSettings()) {
        self.tab = tab; self.profile = profile; self.spoofEnabled = spoofEnabled; self.spoofSettings = settings
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
        // Always start blank: the page must not begin loading before Spoof Mode's
        // document script and identity overrides are installed (restored tabs
        // used to load first and were only partly covered).
        let startURL = URL(string: "about:blank")!
        if let spoofPolicy { applyPolicyState(spoofPolicy(requestedURL)) }
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
                // Cross-site iframes run in their own renderer. Pause each one until
                // its Spoof Mode script is installed, as Prism does with frame sessions.
                _ = try? await browser.devTools("Target.setAutoAttach", params: Self.autoAttach)
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
        guard ready else {
            if let spoofPolicy { applyPolicyState(spoofPolicy(url)) }
            return
        }
        // Switch Spoof Mode before the first request when the website changes it.
        if let spoofPolicy, spoofPolicy(url) != spoofEnabled {
            setSpoof(spoofPolicy(url), settings: spoofSettings)
            let configuration = configurationTask
            Task { [weak self] in
                await configuration?.value
                guard let self, self.requestedURL == url else { return }
                self.browser?.load(url)
            }
            return
        }
        browser?.load(url)
    }

    /// Records the site rules' state before the engine is configured.
    private func applyPolicyState(_ enabled: Bool) {
        guard enabled != spoofEnabled else { return }
        spoofEnabled = enabled
        tab?.spoofModeDidChange(enabled)
    }

    func setSpoof(_ enabled: Bool) { setSpoof(enabled, settings: spoofSettings) }
    /// - Parameter reload: reload the page once the change has been applied
    ///   successfully, so the website starts over in the new mode.
    func setSpoof(_ enabled: Bool, settings: SpoofSettings, reload: Bool = false) {
        let changed = enabled != spoofEnabled
        spoofEnabled = enabled
        spoofSettings = settings
        if changed { tab?.spoofModeDidChange(enabled) }
        if !enabled || !settings.screenshare { sharing.stop() }
        guard ready else { return }
        // Apply changes in order; an earlier configuration may still be running.
        let previous = configurationTask
        configurationTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.configureSpoof()
                if reload, self.spoofEnabled == enabled, let url = self.browser?.url, url.isWebURL {
                    self.browser?.reload()
                }
            } catch { self.tab?.session?.notice = error.localizedDescription }
        }
    }
    func waitForConfiguration() async { await configurationTask?.value }

    var spoofActive: Bool { spoofEnabled }
    private var pageSource: String {
        Self.shareBridge + "\n" + SpoofMode.source(spoofSettings,
            resolution: lockedResolution ?? SpoofResolution.current(for: host.window), native: true)
    }
    private var identityOverride: [String: Any] {
        (spoofEnabled ? spoofSettings.identity?.devToolsOverride : nil) ?? ["userAgent": ""]
    }
    /// Native focus emulation keeps blur and focus loss away from the page.
    /// A tab share also uses it so a background shared tab keeps painting.
    private var focusEmulated: Bool { (spoofEnabled && spoofSettings.focusVisibility) || sharing.isSharing }

    private func configureSpoof() async throws {
        guard let browser else { return }
        if let scriptID {
            _ = try await browser.devTools("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": scriptID])
            self.scriptID = nil
        }
        _ = try await browser.devTools("Network.setUserAgentOverride", params: identityOverride)
        await refreshFocusEmulation()
        lockedResolution = spoofEnabled && spoofSettings.fullscreen ? SpoofResolution.current(for: host.window) : nil
        appliedLockScale = nil
        renderedLockScale = nil
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        try await applyViewportLock()
        if spoofEnabled {
            // runImmediately also replaces the script in the live document; a
            // reinstall with new settings keeps an active tab share running.
            let result = try await browser.devTools("Page.addScriptToEvaluateOnNewDocument", params: ["source": pageSource, "runImmediately": true])
            scriptID = result["identifier"] as? String
        } else {
            _ = try await evaluate(SpoofMode.restoreSource)
        }
        for session in Array(frameSessions.keys) { await configureFrameSession(session) }
    }

    func refreshFocusEmulation() async {
        _ = try? await browser?.devTools("Emulation.setFocusEmulationEnabled", params: ["enabled": focusEmulated])
    }

    // MARK: Fullscreen lock

    /// The page view's frame: letterboxed to the locked resolution's aspect ratio.
    func pageFrame(in bounds: CGRect) -> CGRect {
        guard let lockedResolution, bounds.width >= 2, bounds.height >= 2 else { return bounds }
        return SpoofResolution.fit(lockedResolution, in: bounds).frame
    }

    private var lockScale: CGFloat? {
        guard let lockedResolution else { return nil }
        let bounds = host.pageBounds
        guard bounds.width >= 2, bounds.height >= 2 else { return appliedLockScale ?? 1 }
        return SpoofResolution.fit(lockedResolution, in: bounds).scale
    }

    /// The fraction of a screencast frame the page occupies. Under the fullscreen
    /// lock, Chromium sizes frames to the locked resolution but paints the page
    /// at the emulation scale in the top-left corner. This follows the scale the
    /// page was painted at, not the live view size, which changes first.
    var captureCrop: CGSize {
        guard lockedResolution != nil, let scale = renderedLockScale ?? appliedLockScale else { return CGSize(width: 1, height: 1) }
        let crop = min(1, max(0.01, scale))
        return CGSize(width: crop, height: crop)
    }

    /// Screencast frames can lag the page's real geometry by a few hundred
    /// milliseconds after a resize or scale change; later frames are reliable.
    static let frameSettleTime: TimeInterval = 0.6

    /// The page view changed size: frames composed around now may mix the old
    /// and new geometry, so a shared stream skips them.
    func pageViewDidResize() {
        guard sharing.isSharing else { return }
        sharing.acceptFrames(after: Date().timeIntervalSince1970 + Self.frameSettleTime)
    }

    /// Applies any pending scale change now and waits for it.
    func settleViewport() async {
        host.layoutSubtreeIfNeeded()
        try? await applyViewportLock()
    }

    func viewportDidChange() {
        guard ready, lockedResolution != nil, host.window != nil, lockScale != appliedLockScale else { return }
        Task { [weak self] in try? await self?.applyViewportLock() }
    }

    /// The page renders at the locked resolution, scaled down to fit its view,
    /// so its layout and metrics stay identical in and out of real fullscreen.
    private func applyViewportLock() async throws {
        guard let browser else { return }
        if let lockedResolution, let scale = lockScale {
            guard appliedLockScale != scale else { return }
            appliedLockScale = scale
            metricsOverridden = true
            // A shared stream keeps its last frame until the page has painted at
            // the new scale, so the cast never shows a zoom step.
            let holding = sharing.isSharing
            if holding { sharing.beginHold() }
            #if DEBUG
            sharing.traceLog?("scale apply \(scale) view=\(browser.nativeView?.frame.size ?? .zero)")
            #endif
            defer { if holding { sharing.endHold(settle: 0.05) } }
            _ = try await browser.devTools("Emulation.setDeviceMetricsOverride", params: [
                "width": Int(lockedResolution.width), "height": Int(lockedResolution.height),
                "deviceScaleFactor": 0, "mobile": false, "scale": scale,
                "screenWidth": Int(lockedResolution.width), "screenHeight": Int(lockedResolution.height)
            ])
            if holding {
                // Screencast frames can arrive late. Frames swapped before the page
                // painted at the new scale are dropped by their own timestamp.
                let painted = try? await evaluate("""
                    Promise.race([new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(Date.now())))),
                                  new Promise(r => setTimeout(() => r(Date.now()), 200))])
                    """) as? Double
                sharing.acceptFrames(after: (painted ?? Date().timeIntervalSince1970 * 1000) / 1000 + Self.frameSettleTime)
                #if DEBUG
                sharing.traceLog?("painted at \((painted ?? 0) / 1000 - Date().timeIntervalSince1970) relative-to-now")
                #endif
            }
            if appliedLockScale == scale { renderedLockScale = scale }
            #if DEBUG
            sharing.traceLog?("scale rendered \(scale) applied=\(appliedLockScale ?? -1)")
            #endif
        } else if metricsOverridden, !captureViewportActive {
            metricsOverridden = false
            _ = try? await browser.devTools("Emulation.clearDeviceMetricsOverride")
        }
    }

    // MARK: Out-of-process iframes

    private static let autoAttach: [String: Any] = ["autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true]

    private func attachedTarget(_ params: [String: Any]) {
        guard let browser, let session = params["sessionId"] as? String,
              let info = params["targetInfo"] as? [String: Any] else { return }
        let waiting = params["waitingForDebugger"] as? Bool == true
        guard info["type"] as? String == "iframe" else {
            if waiting { browser.sendDevToolsMessage("Runtime.runIfWaitingForDebugger", params: [:], sessionID: session) }
            return
        }
        frameSessions[session] = ""
        Task { [weak self] in
            guard let self else { return }
            _ = try? await browser.devTools("Target.setAutoAttach", params: Self.autoAttach, sessionID: session)
            _ = try? await browser.devTools("Page.enable", sessionID: session)
            await configureFrameSession(session)
            if waiting { _ = try? await browser.devTools("Runtime.runIfWaitingForDebugger", sessionID: session) }
        }
    }

    private func configureFrameSession(_ session: String) async {
        guard let browser, let previous = frameSessions[session] else { return }
        if !previous.isEmpty {
            _ = try? await browser.devTools("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": previous], sessionID: session)
            frameSessions[session] = ""
        }
        _ = try? await browser.devTools("Network.setUserAgentOverride", params: identityOverride, sessionID: session)
        _ = try? await browser.devTools("Emulation.setFocusEmulationEnabled", params: ["enabled": focusEmulated], sessionID: session)
        if spoofEnabled {
            let result = try? await browser.devTools("Page.addScriptToEvaluateOnNewDocument",
                params: ["source": pageSource, "runImmediately": true], sessionID: session)
            if frameSessions[session] != nil { frameSessions[session] = result?["identifier"] as? String ?? "" }
        } else {
            _ = try? await browser.devTools("Runtime.evaluate", params: ["expression": SpoofMode.restoreSource], sessionID: session)
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
        if params[CefBrowser.devToolsSessionKey] != nil {
            // Child sessions: only iframe attachment bookkeeping is relevant.
            if method == "Target.attachedToTarget" { attachedTarget(params) }
            else if method == "Target.detachedFromTarget", let session = params["sessionId"] as? String {
                frameSessions.removeValue(forKey: session)
            }
            return
        }
        switch method {
        case "Target.attachedToTarget": attachedTarget(params)
        case "Target.detachedFromTarget":
            if let session = params["sessionId"] as? String { frameSessions.removeValue(forKey: session) }
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
                    let value = try await sharing.receive(request, enabled: spoofEnabled && spoofSettings.screenshare)
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
        // The fullscreen lock already keeps the page at one size across tab switches.
        if let lockedResolution { captureViewportActive = true; return lockedResolution }
        guard let browser,
              let viewport = try await evaluate("({width:innerWidth,height:innerHeight,scale:devicePixelRatio})") as? [String: Double],
              let width = viewport["width"], let height = viewport["height"], width >= 2, height >= 2 else {
            throw failure("The shared page is not ready.")
        }
        _ = try await browser.devTools("Emulation.setDeviceMetricsOverride", params: [
            "width": Int(width), "height": Int(height), "deviceScaleFactor": viewport["scale"] ?? 1,
            "mobile": false, "screenWidth": Int(width), "screenHeight": Int(height)
        ])
        captureViewportActive = true
        metricsOverridden = true
        return CGSize(width: width, height: height)
    }

    func endCaptureViewport() async {
        captureViewportActive = false
        appliedLockScale = nil
        try? await applyViewportLock()
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
    func browser(_ b: CefBrowser, willNavigateMainFrameTo url: URL?, isRedirect: Bool) {
        guard ready, let spoofPolicy, let url, url.isWebURL else { return }
        let wanted = spoofPolicy(url)
        guard wanted != spoofEnabled else { return }
        // Moving to or from a selected website. The change is usually applied
        // before the new document starts; the load is verified to be sure.
        verifyAfterLoad = true
        setSpoof(wanted, settings: spoofSettings)
    }

    /// After a navigation switched Spoof Mode, reload once if the document
    /// started before the change took effect.
    private func verifySpoofedDocument() async {
        guard verifyAfterLoad, let browser, let url = browser.url, url.isWebURL else { return }
        verifyAfterLoad = false
        await configurationTask?.value
        let expectedAgent = spoofEnabled ? spoofSettings.identity?.userAgent : nil
        let script = "({active: !!window.\(SpoofMode.stateKey), agent: navigator.userAgent})"
        guard let state = try? await evaluate(script) as? [String: Any] else { return }
        let active = state["active"] as? Bool == true
        let agentMatches = expectedAgent.map { state["agent"] as? String == $0 } ?? true
        guard active != spoofEnabled || !agentMatches, verificationReloadURL != url else { return }
        verificationReloadURL = url
        browser.reload()
    }

    func browser(_ b: CefBrowser, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard ready else { return }
        if !loading, verifyAfterLoad { Task { [weak self] in await self?.verifySpoofedDocument() } }
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
        // Spoof Mode keeps reporting fullscreen; the window itself follows the
        // page's real requests, as in a normal browser.
        guard let window = host.window, window.styleMask.contains(.fullScreen) != fullscreen else { return }
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
        if let view = engine?.browser?.nativeView {
            let frame = engine?.pageFrame(in: pageBounds) ?? pageBounds
            if view.frame.size != frame.size { engine?.pageViewDidResize() }
            view.frame = frame
        }
        engine?.viewportDidChange()
    }
}
