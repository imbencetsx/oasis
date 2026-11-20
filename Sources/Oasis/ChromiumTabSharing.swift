import AppKit
import CefKit

/// Captures the originating Chromium page, independently of browser chrome.
@MainActor final class ChromiumTabSharing {
    private weak var engine: ChromiumTabEngine?
    private var token: String?
    private var framing: WebViewCaptureFraming?
    private var initialSize = CGSize.zero
    private var cursor: SharedCursor?
    private var surface = "monitor"
    private var parkedPoint: CGPoint?
    private var latestFrame: String?
    /// The part of the latest frame the page occupies (see `ChromiumTabEngine.captureCrop`).
    private var latestCrop = CGSize(width: 1, height: 1)
    /// Frames are dropped briefly while the fullscreen lock's scale changes.
    private var holdFramesUntil = Date.distantPast
    private var frameSequence = 0
    private var deliveredSequence = -1
    private var cursorImage: NSImage?
    private var cursorURL: String?
    private var cleanupTask: Task<Void, Never>?
    private var requesting = false
    private var generation = UUID()
    private var statusItem: NSStatusItem?
    private var activity: NSObjectProtocol?
    private var lastInsideScreenPoint: CGPoint?
    private var wasAway = false
    var isSharing: Bool { token != nil }

    init(engine: ChromiumTabEngine) { self.engine = engine }

    func stop() {
        generation = UUID()
        let oldToken = token
        token = nil; framing = nil; cursor = nil
        latestFrame = nil; frameSequence = 0; deliveredSequence = -1
        cursorImage = nil; cursorURL = nil; parkedPoint = nil
        lastInsideScreenPoint = nil; wasAway = false
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
            await engine.refreshFocusEmulation()
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
            let chosen = await ShareConsent.ask(host: browser.url?.host ?? "this website", window: window, reportAs: true)
            guard let chosen, requestGeneration == generation else { throw failure("Tab sharing was not allowed.") }
            surface = chosen
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
            await engine.refreshFocusEmulation()
            do {
                // Under the fullscreen lock, frames have the locked resolution with the
                // page drawn scaled into their top-left corner. Request them large
                // enough to keep the page's detail; each frame is cropped to the page.
                var maxSize = CGSize(width: framing.width, height: framing.height)
                if let lock = engine.lockedResolution {
                    let backing = engine.host.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
                    maxSize = CGSize(width: lock.width * backing, height: lock.height * backing)
                }
                _ = try await browser.devTools("Page.startScreencast", params: [
                    "format": "jpeg", "quality": 75, "maxWidth": Int(maxSize.width),
                    "maxHeight": Int(maxSize.height), "everyNthFrame": 1
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
            return ["token": token!, "width": framing.width, "height": framing.height, "surface": surface]
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
            result["crop"] = [Double(latestCrop.width), Double(latestCrop.height)]
        }
        if let cursor, let cursorURL {
            let scale = Double(framing.width) / initialSize.width
            result["cursor"] = ["image": cursorURL,
                "x": (cursor.position.x - cursor.hotSpot.x) * scale,
                "y": (cursor.position.y - cursor.hotSpot.y) * scale,
                "width": cursor.size.width * scale, "height": cursor.size.height * scale]
        } else {
            result["cursor"] = NSNull()
        }
        return result
    }

    /// Retain a single compositor frame; dropping superseded frames keeps latency bounded.
    /// The page's scale is changing (window resize or fullscreen). Frames in
    /// flight still show the old scale, so keep the last good frame meanwhile.
    func lockScaleWillChange() {
        guard token != nil else { return }
        holdFramesUntil = Date().addingTimeInterval(0.25)
    }

    #if DEBUG
    var frameObserver: (([String: Any]) -> Void)?
    #endif

    func receiveScreencastFrame(_ params: [String: Any]) {
        guard let browser = engine?.browser, let sessionID = params["sessionId"] as? Int else { return }
        #if DEBUG
        frameObserver?(params)
        #endif
        if token != nil, let data = params["data"] as? String, Date() >= holdFramesUntil, let engine {
            latestFrame = "data:image/jpeg;base64," + data
            latestCrop = engine.captureCrop
            frameSequence += 1
        }
        // Immediately acknowledge the screencast frame so Chromium never throttles or stalls.
        browser.sendDevToolsMessage("Page.screencastFrameAck", params: ["sessionId": sessionID])
    }

    /// The pointer drawn into the shared stream, in page CSS pixels.
    private struct SharedCursor { var position: CGPoint; var hotSpot: CGPoint; var size: CGSize }

    /// Distance from the edge where the pointer is parked (~1 cm at 96 CSS DPI), as in Prism.
    private static let parkingMargin: CGFloat = 38

    private func updateCursor(_ host: ChromiumPageHost) {
        guard let engine, ScreenRecordingDetector.isRecordingActive(for: engine.tab) else {
            wasAway = false
            lastInsideScreenPoint = nil
            return
        }
        let containment = engine.spoofSettings.screenshareCursor
        let frame = engine.pageFrame(in: host.pageBounds)
        guard frame.width >= 1, initialSize.width >= 1 else { return }
        let cssPerPoint = initialSize.width / frame.width
        let visibleWindow = host.window.flatMap { $0 === engine.captureWindow ? nil : $0 }
        // Where the pointer is relative to the page, when this tab is on screen.
        var exitPoint: CGPoint?
        var inside = false
        if let tab = engine.tab, tab.session?.selectedID == tab.id,
           tab.session?.showsNewTabSearch != true, !tab.showsReader, let window = visibleWindow,
           window.isVisible, window.isOnActiveSpace, !window.isMiniaturized, !host.isHiddenOrHasHiddenAncestor {
            let point = host.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            exitPoint = CGPoint(x: (point.x - frame.minX) * cssPerPoint, y: (point.y - frame.minY) * cssPerPoint)
            if NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil,
               frame.contains(point), host.visibleRect.contains(point), let root = window.contentView {
                let rootPoint = root.superview?.convert(point, from: host) ?? host.convert(point, to: nil)
                if let hit = root.hitTest(rootPoint), hit === host || hit.isDescendant(of: host) { inside = true }
            }
        }
        guard inside, let exitPoint else {
            if !wasAway, containment { park(exit: exitPoint, frame: frame, cssPerPoint: cssPerPoint, window: visibleWindow, host: host) }
            wasAway = true
            if !containment { cursor = nil }
            return
        }
        if wasAway, containment, let lastPoint = lastInsideScreenPoint {
            // Returning: continue from where the stream last showed the pointer.
            wasAway = false
            parkedPoint = nil
            if let primary = NSScreen.screens.first {
                CGWarpMouseCursorPosition(CGPoint(x: lastPoint.x, y: primary.frame.maxY - lastPoint.y))
            }
            return
        }
        wasAway = false
        parkedPoint = nil
        lastInsideScreenPoint = NSEvent.mouseLocation
        let current = NSCursor.current
        if cursorImage !== current.image,
           let tiff = current.image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            cursorImage = current.image
            cursorURL = "data:image/png;base64," + png.base64EncodedString()
        }
        cursor = SharedCursor(position: exitPoint,
            hotSpot: CGPoint(x: current.hotSpot.x * cssPerPoint, y: current.hotSpot.y * cssPerPoint),
            size: CGSize(width: current.image.size.width * cssPerPoint, height: current.image.size.height * cssPerPoint))
    }

    /// Parks the shared pointer ~1 cm inside the edge it left through, so the
    /// stream never shows it leaving the page. The page's own pointer position
    /// (and :hover) moves there too.
    private func park(exit: CGPoint?, frame: CGRect, cssPerPoint: CGFloat, window: NSWindow?, host: ChromiumPageHost) {
        let width = frame.width * cssPerPoint, height = frame.height * cssPerPoint
        let margin = min(Self.parkingMargin, width / 2, height / 2)
        let last = cursor?.position ?? CGPoint(x: width / 2, y: height / 2)
        var edge = ""
        var origin = last
        if let exit {
            let overshoot = [("left", -exit.x), ("right", exit.x - width), ("top", -exit.y), ("bottom", exit.y - height)]
                .max { $0.1 < $1.1 }!
            if overshoot.1 >= 0 { edge = overshoot.0; origin = exit }
        }
        let x = min(max(origin.x, 0), width), y = min(max(origin.y, 0), height)
        if edge.isEmpty {
            let distances = [("left", x), ("right", width - x), ("top", y), ("bottom", height - y)]
            edge = distances.min { $0.1 < $1.1 }!.0
        }
        let clampedX = min(max(x, margin), width - margin), clampedY = min(max(y, margin), height - margin)
        let parked: CGPoint
        switch edge {
        case "left": parked = CGPoint(x: margin, y: clampedY)
        case "right": parked = CGPoint(x: width - margin, y: clampedY)
        case "top": parked = CGPoint(x: clampedX, y: margin)
        default: parked = CGPoint(x: clampedX, y: height - margin)
        }
        parkedPoint = parked
        if cursor != nil { cursor?.position = parked }
        else {
            let image = cursorImage ?? NSCursor.arrow.image
            if cursorURL == nil, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                cursorImage = image
                cursorURL = "data:image/png;base64," + png.base64EncodedString()
            }
            let hot = NSCursor.arrow.hotSpot
            cursor = SharedCursor(position: parked, hotSpot: CGPoint(x: hot.x * cssPerPoint, y: hot.y * cssPerPoint),
                size: CGSize(width: image.size.width * cssPerPoint, height: image.size.height * cssPerPoint))
        }
        // Returning to the tab continues from the parked point.
        if let window {
            let local = CGPoint(x: frame.minX + parked.x / cssPerPoint, y: frame.minY + parked.y / cssPerPoint)
            lastInsideScreenPoint = window.convertPoint(toScreen: host.convert(local, to: nil))
        }
        engine?.browser?.sendDevToolsMessage("Input.dispatchMouseEvent", params: [
            "type": "mouseMoved", "x": Double(parked.x), "y": Double(parked.y), "button": "none"
        ])
    }

    private lazy var menuTarget = SharingMenuTarget { [weak self] in self?.stop() }
    private func failure(_ message: String) -> NSError { NSError(domain: "Oasis.TabSharing", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor private final class SharingMenuTarget: NSObject {
    let stop: () -> Void
    init(stop: @escaping () -> Void) { self.stop = stop }
    @objc func stopSharing() { stop() }
}
