import AppKit
import CefKit

/// Captures the originating Chromium page, independently of browser chrome.
@MainActor final class ChromiumTabSharing {
    private weak var engine: ChromiumTabEngine?
    private var token: String?
    private var framing: WebViewCaptureFraming?
    private var initialSize = CGSize.zero
    private var cursor: WebViewCaptureCursor?
    private var latestFrame: String?
    private var frameSequence = 0
    private var deliveredSequence = -1
    private var cursorImage: NSImage?
    private var cursorURL: String?
    private var cleanupTask: Task<Void, Never>?
    private var requesting = false
    private var generation = UUID()
    private var statusItem: NSStatusItem?
    private var activity: NSObjectProtocol?

    init(engine: ChromiumTabEngine) { self.engine = engine }

    func stop() {
        generation = UUID()
        let oldToken = token
        token = nil; framing = nil; cursor = nil
        latestFrame = nil; frameSequence = 0; deliveredSequence = -1
        cursorImage = nil; cursorURL = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard let engine, let oldToken else { return }
        engine.execute("window['\(SpoofMode.stateKey)']?.stopSharing?.('\(oldToken)')")
        let previousCleanup = cleanupTask
        cleanupTask = Task {
            await previousCleanup?.value
            _ = try? await engine.browser?.devTools("Page.stopScreencast")
            await engine.endCaptureViewport()
            _ = try? await engine.browser?.devTools("Emulation.setFocusEmulationEnabled", params: ["enabled": false])
        }
    }

    func receive(_ body: [String: String], enabled: Bool) async throws -> Any {
        guard enabled, let engine, let browser = engine.browser,
              browser.url?.scheme == "https", let action = body["action"] else {
            throw failure("Tab sharing requires an HTTPS top-level page and Spoof Mode.")
        }
        if action == "begin" {
            guard token == nil, !requesting, let window = engine.host.window, window.attachedSheet == nil else {
                throw failure("Tab sharing is already active or a dialog is open.")
            }
            requesting = true
            defer { requesting = false }
            let requestGeneration = generation
            await cleanupTask?.value
            guard requestGeneration == generation else { throw failure("Tab sharing was cancelled.") }
            let alert = NSAlert()
            alert.messageText = "Share this tab with \(browser.url?.host ?? "this website")?"
            alert.informativeText = "Only this tab's website will be shared, without browser controls. The cursor stays at its last page position when you leave the tab. Switching tabs won't change the shared page. Stop from the Sharing menu in the macOS menu bar. Available only in Spoof Mode."
            alert.addButton(withTitle: "Don't Allow"); alert.addButton(withTitle: "Share Tab")
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .alertSecondButtonReturn, requestGeneration == generation else { throw failure("Tab sharing was not allowed.") }
            initialSize = try await engine.beginCaptureViewport()
            guard requestGeneration == generation else {
                await engine.endCaptureViewport()
                throw failure("Tab sharing was cancelled.")
            }
            guard initialSize.width >= 2, initialSize.height >= 2 else { throw failure("The shared page is not ready.") }
            let framing = WebViewCaptureFraming(contentSize: initialSize)
            self.framing = framing
            latestFrame = nil; frameSequence = 0; deliveredSequence = -1
            token = UUID().uuidString
            _ = try? await browser.devTools("Emulation.setFocusEmulationEnabled", params: ["enabled": true])
            do {
                _ = try await browser.devTools("Page.startScreencast", params: [
                    "format": "jpeg", "quality": 75, "maxWidth": framing.width,
                    "maxHeight": framing.height, "everyNthFrame": 1
                ])
                // The bridge needs a first frame before it can return a MediaStream.
                for _ in 0..<200 {
                    if latestFrame != nil || requestGeneration != generation { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard latestFrame != nil, requestGeneration == generation else {
                    throw failure("Chromium did not produce the initial shared frame.")
                }
            } catch {
                stop()
                throw error
            }
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Sharing an Oasis tab")
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "Sharing"
            let menu = NSMenu()
            let heading = NSMenuItem(title: "Sharing tab with \(browser.url?.host ?? "website")", action: nil, keyEquivalent: "")
            heading.isEnabled = false; menu.addItem(heading)
            let stopItem = NSMenuItem(title: "Stop Sharing", action: #selector(SharingMenuTarget.stopSharing), keyEquivalent: "")
            stopItem.target = menuTarget; menu.addItem(stopItem); item.menu = menu
            statusItem = item
            return ["token": token!, "width": framing.width, "height": framing.height]
        }
        guard let token, body["token"] == token else { return ["ended": true] }
        if action == "end" { stop(); return true }
        guard action == "frame", let framing, let latestFrame else { return ["retry": true] }
        // Keep the originating renderer attached and painting after tab switches.
        try await engine.prepareCaptureSurface()
        guard self.token == token else { return ["ended": true] }
        updateCursor(engine.host)
        var result: [String: Any] = [:]
        if deliveredSequence == frameSequence {
            result["same"] = true
        } else {
            deliveredSequence = frameSequence
            result["image"] = latestFrame
        }
        if let cursor, let cursorURL {
            let scale = Double(framing.width) / initialSize.width
            result["cursor"] = ["image": cursorURL,
                "x": (cursor.position.x - cursor.hotSpot.x) * scale,
                "y": (cursor.position.y - cursor.hotSpot.y) * scale,
                "width": cursor.size.width * scale, "height": cursor.size.height * scale]
        }
        return result
    }

    /// Retain a single compositor frame; dropping superseded frames keeps latency bounded.
    func receiveScreencastFrame(_ params: [String: Any]) {
        guard let browser = engine?.browser, let sessionID = params["sessionId"] as? Int else { return }
        if token != nil, let data = params["data"] as? String {
            latestFrame = "data:image/jpeg;base64," + data
            frameSequence += 1
        }
        // Immediately acknowledge the screencast frame so Chromium never throttles or stalls.
        browser.sendDevToolsMessage("Page.screencastFrameAck", params: ["sessionId": sessionID])
    }

    private func updateCursor(_ host: ChromiumPageHost) {
        guard let tab = engine?.tab, tab.session?.selectedID == tab.id,
              tab.session?.showsNewTabSearch != true, !tab.showsReader,
              NSApp.isActive, let window = host.window, window !== engine?.captureWindow,
              window.isKeyWindow, window.isVisible, window.attachedSheet == nil,
              window.isOnActiveSpace, !window.isMiniaturized, !host.isHiddenOrHasHiddenAncestor else { return }
        let point = host.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard host.pageBounds.contains(point), host.visibleRect.contains(point),
              let root = window.contentView else { return }
        let rootPoint = root.superview?.convert(point, from: host) ?? host.convert(point, to: nil)
        guard let hit = root.hitTest(rootPoint), hit === host || hit.isDescendant(of: host) else { return }
        let current = NSCursor.current
        if cursorImage !== current.image,
           let tiff = current.image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            cursorImage = current.image
            cursorURL = "data:image/png;base64," + png.base64EncodedString()
        }
        guard let image = current.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        cursor = WebViewCaptureCursor(image: image,
            position: CGPoint(x: point.x, y: point.y - host.topInset), hotSpot: current.hotSpot, size: current.image.size)
    }

    private lazy var menuTarget = SharingMenuTarget { [weak self] in self?.stop() }
    private func failure(_ message: String) -> NSError { NSError(domain: "Oasis.TabSharing", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor private final class SharingMenuTarget: NSObject {
    let stop: () -> Void
    init(stop: @escaping () -> Void) { self.stop = stop }
    @objc func stopSharing() { stop() }
}
