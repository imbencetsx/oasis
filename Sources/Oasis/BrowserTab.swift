import SwiftUI
import WebKit
import UniformTypeIdentifiers

@MainActor @Observable
final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let isPrivate: Bool
    @ObservationIgnored private var contentView: WKWebView?
    @ObservationIgnored private let configuration: WKWebViewConfiguration
    @ObservationIgnored private var deferredURL: URL?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var isHistoryNavigation = false
    var hasWebView: Bool { contentView != nil }
    var webView: WKWebView {
        if let contentView { return contentView }
        return makeWebView()
    }
    var favicon: NSImage?
    var chromeColor: NSColor?
    var sidebarTint: NSColor? {
        guard let color = chromeColor?.usingColorSpace(.sRGB) else { return chromeColor }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        let minimum = channels.min() ?? 0
        let maximum = channels.max() ?? 0
        // White and near-white pages leave the sidebar’s desktop vibrancy untinted.
        return minimum > 0.88 && maximum - minimum < 0.08 ? nil : chromeColor
    }
    var sidebarColorScheme: ColorScheme? { sidebarTint == nil ? nil : chromeColorScheme }
    var chromeColorScheme: ColorScheme? {
        guard let color = chromeColor?.usingColorSpace(.sRGB) else { return nil }
        let brightness = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return brightness < 0.5 ? .dark : .light
    }
    var title = "Empty Tab"
    var url: URL? = URL(string: "about:blank")
    var isBlankPage = true
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var isPinned = false
    var spaceID: UUID?
    var errorMessage: String?
    var zoom = 1.0
    var findText = ""
    var findResult = ""
    var readerContent: ReaderContent?
    var showsReader = false
    @ObservationIgnored weak var session: BrowserSession?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var spoofModeEnabled: Bool
    @ObservationIgnored private let spoofFrames: SpoofFrameCoverage

    init(isPrivate: Bool, configuration: WKWebViewConfiguration? = nil, dataStore: WKWebsiteDataStore? = nil, spoofModeEnabled: Bool = false) {
        self.isPrivate = isPrivate
        self.spoofModeEnabled = spoofModeEnabled
        let coverage = SpoofFrameCoverage()
        spoofFrames = coverage
        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil { config.websiteDataStore = dataStore ?? (isPrivate ? .nonPersistent() : .default()) }
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        self.configuration = config
        super.init()
    }

    private func makeWebView() -> WKWebView {
        spoofFrames.prepare(configuration.userContentController)
        SpoofMode.configure(configuration.userContentController, enabled: spoofModeEnabled)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        contentView = webView
        webView.obscuredContentInsets = NSEdgeInsets(top: 64, left: 0, bottom: 0, right: 0)
        spoofFrames.attach(webView, enabled: spoofModeEnabled)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = UserDefaults.standard.bool(forKey: "enableWebInspector")
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.requestSync() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.requestSync() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.requestSync() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.requestSync() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.requestSync() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.requestSync() },
            webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in self?.requestSync() },
            NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.updateWebsiteAppearance() }
            }
        ]
        return webView
    }

    fileprivate func updateWebsiteAppearance() {
        let host = (url?.host ?? "").lowercased()
        let isGoogle = host == "google.com" || host.hasSuffix(".google.com")
            || host.hasPrefix("google.") || host.hasPrefix("www.google.")
        // Google receives the system preference through native WebKit media-query support.
        // A theme explicitly saved by the website still takes precedence.
        let appearance = isGoogle ? NSApp.effectiveAppearance : nil
        if webView.appearance?.name != appearance?.name { webView.appearance = appearance }
    }

    private nonisolated func requestSync() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { scheduleSync() }
        } else {
            Task { @MainActor [weak self] in self?.scheduleSync() }
        }
    }

    private func scheduleSync() {
        guard syncTask == nil, !isClosed else { return }
        syncTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.syncTask = nil
            self.sync()
        }
    }

    private func sync() {
        guard !isClosed, let webView = contentView else { return }
        // Read WebKit’s derived page color; never override it or modify the document.
        let color = isBlankPage ? nil : webView.underPageBackgroundColor
        if chromeColor != color { chromeColor = color }
        let address = webView.url ?? url
        if url != address { url = address; updateWebsiteAppearance() }
        let pageTitle = isBlankPage ? "Empty Tab" : webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? url?.displayHost ?? "Untitled"
        if title != pageTitle { title = pageTitle }
        if isLoading != webView.isLoading { isLoading = webView.isLoading }
        if progress != webView.estimatedProgress { progress = webView.estimatedProgress }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    func prepareRestoration(url: URL?) {
        guard let url else { return }
        self.url = url
        isBlankPage = url.absoluteString == "about:blank"
        title = isBlankPage ? "Empty Tab" : url.displayHost
        deferredURL = url
    }

    func loadIfNeeded() {
        if let deferredURL { load(deferredURL) }
    }

    func load(_ url: URL) {
        guard !isClosed else { return }
        deferredURL = nil
        isHistoryNavigation = false
        self.url = url; isBlankPage = url.absoluteString == "about:blank"; errorMessage = nil; showsReader = false; readerContent = nil
        updateWebsiteAppearance()
        if isBlankPage { chromeColor = nil }
        if session?.selectedID == id { session?.showsNewTabSearch = false }
        title = isBlankPage ? "Empty Tab" : url.displayHost
        favicon = nil; faviconTask?.cancel()
        if url.isFileURL { webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url: url)) }
        session?.save()
    }
    func setSpoofMode(_ enabled: Bool) {
        spoofModeEnabled = enabled
        guard let webView = contentView else { return }
        SpoofMode.configure(webView.configuration.userContentController, enabled: enabled)
        spoofFrames.apply(enabled: enabled)
        applySpoofModeToDocument()
    }
    private func applySpoofModeToDocument() {
        guard !isBlankPage else { return }
        // Always use the current preference; navigation failures never switch the toggle off.
        webView.evaluateJavaScript(spoofModeEnabled ? SpoofMode.source : SpoofMode.restoreSource) { _, _ in }
    }
    func setTopInset(_ topInset: CGFloat) {
        let insets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        if webView.obscuredContentInsets.top != topInset { webView.obscuredContentInsets = insets }
    }
    func goBack() { showsReader = false; errorMessage = nil; isHistoryNavigation = true; webView.goBack() }
    func goForward() { showsReader = false; errorMessage = nil; isHistoryNavigation = true; webView.goForward() }
    func reload() {
        errorMessage = nil
        if deferredURL != nil { loadIfNeeded() } else { webView.reload() }
    }
    func stop() { webView.stopLoading() }
    func setZoom(_ value: Double) { zoom = min(3, max(0.5, value)); webView.pageZoom = zoom }
    func close() {
        guard !isClosed else { return }
        isClosed = true
        deferredURL = nil
        syncTask?.cancel(); syncTask = nil
        spoofFrames.close()
        faviconTask?.cancel()
        contentView?.stopLoading()
        contentView?.pauseAllMediaPlayback(completionHandler: nil)
        contentView?.navigationDelegate = nil; contentView?.uiDelegate = nil
        observations.removeAll()
    }
    func find(backwards: Bool = false) {
        guard !findText.isEmpty else { findResult = ""; return }
        let config = WKFindConfiguration()
        config.backwards = backwards; config.wraps = true; config.caseSensitive = false
        webView.find(findText, configuration: config) { [weak self] result in self?.findResult = result.matchFound ? "" : "No matches" }
    }
    func printPage() {
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.run()
    }
    func savePDF() {
        webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            self?.saveExport(result, extension: "pdf", type: .pdf)
        }
    }
    func saveArchive() {
        webView.createWebArchiveData { [weak self] result in
            self?.saveExport(result, extension: "webarchive", type: UTType(filenameExtension: "webarchive") ?? .data)
        }
    }
    private func saveExport(_ result: Result<Data, Error>, extension suffix: String, type: UTType) {
        switch result {
        case .success(let data):
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "/", with: "-" )).\(suffix)"
            panel.allowedContentTypes = [type]
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic) }
                catch { self?.session?.notice = error.localizedDescription }
            }
        case .failure(let error): session?.notice = error.localizedDescription
        }
    }

    func toggleReader() {
        if showsReader { showsReader = false; return }
        // Read text only. The extracted article never executes scripts or loads remote resources.
        webView.evaluateJavaScript("""
        (() => {
          const root = document.querySelector('article') || document.querySelector('main') || document.body;
          const paragraphs = [...root.querySelectorAll('h1,h2,h3,p,blockquote')]
            .map(e => e.innerText.trim()).filter(t => t.length > 0);
          return { title: document.title, text: paragraphs.join('\\n\\n') };
        })()
        """) { [weak self] value, error in
            guard let self else { return }
            guard error == nil, let article = value as? [String: String], let text = article["text"], text.count > 100 else {
                self.session?.notice = "Reader couldn’t find an article on this page."; return
            }
            self.readerContent = ReaderContent(title: article["title"] ?? self.title, text: text)
            self.showsReader = true
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        SpoofMode.configure(webView.configuration.userContentController, enabled: spoofModeEnabled)
        errorMessage = nil; showsReader = false; readerContent = nil
        sync()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        isBlankPage = webView.url?.absoluteString == "about:blank"
        if isHistoryNavigation {
            // Cached pages do not rerun document-start scripts. Reconcile their
            // frame tree explicitly; page-world lifecycle suppression can also
            // prevent the isolated world's pageshow listener from receiving it.
            applySpoofModeToDocument()
            spoofFrames.refreshCachedFrames()
        }
        isHistoryNavigation = false
        sync()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isBlankPage = webView.url?.absoluteString == "about:blank"
        sync()
        loadFavicon()
        if !isPrivate, let url, url.isWebURL { session?.library.recordVisit(url: url, title: title) }
        session?.save()
    }
    private func loadFavicon() {
        guard let pageURL = url, pageURL.isWebURL else { return }
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            guard let self else { return }
            let declared = try? await webView.evaluateJavaScript(
                "document.querySelector('link[rel~=icon], link[rel=apple-touch-icon]')?.href ?? ''"
            ) as? String
            let iconURL = declared.flatMap { URL(string: $0) }.flatMap { $0.isWebURL ? $0 : nil }
                ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
            guard let iconURL else { return }
            guard let image = await FaviconLoader.download(iconURL) else { return }
            guard !Task.isCancelled, self.url == pageURL else { return }
            favicon = image
            session?.library.storeFavicon(image, for: pageURL)
        }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        errorMessage = error.localizedDescription; isLoading = false
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorMessage = "The webpage stopped responding. Reload it to continue."; isLoading = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true {
            isHistoryNavigation = navigationAction.navigationType == .backForward
        }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "file", "data", "blob"].contains(scheme) {
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated else { return }
            ask(title: "Open another app?", message: "This link wants to open \(scheme): in another application.", buttons: ["Open App", "Cancel"]) { response in
                if response == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
            }
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download); return }
        if navigationAction.modifierFlags.contains(.command), navigationAction.navigationType == .linkActivated {
            session?.newTab(url: url, select: navigationAction.modifierFlags.contains(.shift))
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { session?.downloads.receive(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { session?.downloads.receive(download) }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let session else { return nil }
        // WebKit supplies the opener's configuration; preserving it is required for window.open.
        let tab = session.newTab(configuration: configuration, spaceID: spaceID)
        tab.isBlankPage = false
        return tab.webView
    }
    func webViewDidClose(_ webView: WKWebView) { session?.closeTab(id) }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        ask(title: frame.request.url?.displayHost ?? "Webpage", message: message, buttons: ["OK"]) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        ask(title: frame.request.url?.displayHost ?? "Webpage", message: message, buttons: ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        ask(title: frame.request.url?.displayHost ?? "Webpage", message: prompt, buttons: ["OK", "Cancel"], accessory: field) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let resource = type == .camera ? "camera" : type == .microphone ? "microphone" : "camera and microphone"
        ask(title: "Allow \(origin.host) to use your \(resource)?", message: "Only allow access if you trust this website.", buttons: ["Don’t Allow", "Allow"]) {
            decisionHandler($0 == .alertSecondButtonReturn ? .grant : .deny)
        }
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(method) else {
            // Includes TLS trust evaluation: never bypass invalid certificates.
            completionHandler(.performDefaultHandling, nil); return
        }
        guard challenge.previousFailureCount < 3 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let username = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        username.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = "Password"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        container.addSubview(username); container.addSubview(password)
        ask(title: "Sign in to \(challenge.protectionSpace.host)", message: "This website requires a username and password.", buttons: ["Sign In", "Cancel"], accessory: container) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(.useCredential, URLCredential(user: username.stringValue, password: password.stringValue, persistence: .forSession))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }
    private func ask(title: String, message: String, buttons: [String], accessory: NSView? = nil,
                     completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window, window.attachedSheet == nil else { completion(.abort); return }
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = accessory
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}

struct ReaderContent { var title: String; var text: String }

struct WebContentView: NSViewRepresentable {
    let tab: BrowserTab
    func makeNSView(context: Context) -> WKWebView {
        roundCorners(tab.webView)
        return tab.webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        tab.updateWebsiteAppearance()
    }
    private func roundCorners(_ webView: WKWebView) {
        webView.wantsLayer = true
        webView.layer?.cornerRadius = BrowserPageFrame.cornerRadius
        webView.layer?.cornerCurve = .continuous
        webView.layer?.masksToBounds = true
    }
}
