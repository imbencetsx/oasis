import AppKit
import ObjectiveC
import ScreenCaptureKit
import WebKit

/// A permission-scoped bridge from getDisplayMedia to this tab's own window.
@MainActor final class WindowScreenSharing: NSObject {
    nonisolated static let source = """
        if (w.HTMLCanvasElement.prototype.captureStream) {
          let mediaDevices = w.navigator.mediaDevices;
          if (!mediaDevices) {
            mediaDevices = {};
            patch(w.navigator, 'mediaDevices', { get: () => mediaDevices });
          }
          patch(mediaDevices, 'getDisplayMedia', { writable: true, value: async function getDisplayMedia(options = {}) {
            if (!w.isSecureContext || w !== w.top)
              throw new w.DOMException('Window sharing requires an HTTPS top-level page.', 'NotAllowedError');
            if (options.video === false)
              throw new w.TypeError('Window sharing requires a video track.');
            if (!w.navigator.userActivation?.isActive)
              throw new w.DOMException('Start window sharing with a click.', 'InvalidStateError');
            const bridge = w.webkit?.messageHandlers?.oasisWindowShare;
            if (!bridge) throw new w.DOMException('Window sharing is unavailable.', 'NotSupportedError');
            let info;
            try { info = await bridge.postMessage({action: 'begin'}); }
            catch (error) { throw new w.DOMException(String(error), 'NotAllowedError'); }
            const canvas = d.createElement('canvas');
            canvas.width = info.width; canvas.height = info.height;
            const context = canvas.getContext('2d');
            let stream, track, timer, stopped = false;
            const finish = () => {
              if (stopped) return;
              stopped = true;
              w.clearTimeout(timer);
              cleanups.delete(finish);
              if (track) {
                nativeStop.call(track);
                track.dispatchEvent(new w.Event('ended'));
              }
              bridge.postMessage({action: 'end', token: info.token}).catch(() => {});
              canvas.width = canvas.height = 0;
            };
            let nativeStop;
            cleanups.add(finish);
            const paint = async () => {
              const frame = await bridge.postMessage({action: 'frame', token: info.token});
              if (stopped) return;
              const image = new w.Image();
              image.src = frame;
              await image.decode();
              if (!stopped) context.drawImage(image, 0, 0, canvas.width, canvas.height);
            };
            try {
              await paint();
              if (stopped) throw new w.DOMException('Window sharing has ended.', 'AbortError');
              stream = canvas.captureStream(10);
              track = stream.getVideoTracks()[0];
              nativeStop = track.stop;
              const nativeSettings = track.getSettings.bind(track);
              Object.defineProperty(track, 'getSettings', { configurable: true, value: () => ({
                ...nativeSettings(), displaySurface: 'monitor', logicalSurface: true, cursor: 'always'
              }) });
              Object.defineProperty(track, 'stop', { configurable: true, value: finish });
              const next = async () => {
                try { await paint(); }
                catch (_) { finish(); }
                if (!stopped) timer = w.setTimeout(next, 100);
              };
              timer = w.setTimeout(next, 100);
              return stream;
            } catch (error) { finish(); throw error; }
          }});
        }
        """
    private weak var webView: WKWebView?
    private var dispatcher: WindowShareDispatcher?
    private var enabled = false
    private var generation = UUID()
    private var token: String?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var statusItem: NSStatusItem?
    private var busy = false
    private var requesting = false

    func attach(_ webView: WKWebView, enabled: Bool) {
        self.webView = webView
        self.enabled = enabled
        let dispatcher = WindowShareDispatcher.shared(for: webView.configuration.userContentController)
        self.dispatcher = dispatcher
        dispatcher.clients.setObject(self, forKey: webView)
    }

    func apply(enabled: Bool) {
        self.enabled = enabled
        if !enabled { stop() }
    }

    @objc func stop() {
        generation = UUID()
        token = nil
        filter = nil
        configuration = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func close() {
        stop()
        if let webView { dispatcher?.remove(webView) }
        webView = nil
        dispatcher = nil
    }

    fileprivate func receive(_ message: WKScriptMessage) async throws -> Any {
        guard enabled, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              let body = message.body as? [String: String], let action = body["action"],
              let webView, message.webView === webView else {
            throw ShareError.message("Window sharing requires an HTTPS top-level page and Spoof Mode.")
        }
        if action == "begin" {
            guard !requesting, token == nil, let window = webView.window,
                  window.attachedSheet == nil else {
                throw ShareError.message("Window sharing is already active or a dialog is open.")
            }
            requesting = true
            defer { requesting = false }
            let requestGeneration = generation
            let alert = NSAlert()
            alert.messageText = "Share this Oasis window with \(message.frameInfo.securityOrigin.host)?"
            alert.informativeText = "The website will see this browser window, including its tabs and sidebar. Stop sharing from the Sharing menu in the macOS menu bar."
            alert.addButton(withTitle: "Don't Allow")
            alert.addButton(withTitle: "Share Window")
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .alertSecondButtonReturn, enabled, generation == requestGeneration else {
                throw ShareError.message("Window sharing was cancelled.")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard enabled, generation == requestGeneration,
                  let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw ShareError.message("The Oasis window is no longer available.")
            }
            let configuration = SCStreamConfiguration()
            // Bound bridge bandwidth while preserving the entire window's aspect ratio.
            let scale = min(1, 1440 / max(1, source.frame.width))
            configuration.width = max(2, Int(source.frame.width * scale))
            configuration.height = max(2, Int(source.frame.height * scale))
            configuration.showsCursor = true
            configuration.ignoreShadowsSingleWindow = true
            self.filter = SCContentFilter(desktopIndependentWindow: source)
            self.configuration = configuration
            let token = UUID().uuidString
            self.token = token
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "Sharing"
            item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Sharing Oasis window")
            let menu = NSMenu()
            menu.addItem(withTitle: "Sharing Oasis with \(message.frameInfo.securityOrigin.host)", action: nil, keyEquivalent: "")
            let stopItem = menu.addItem(withTitle: "Stop Sharing", action: #selector(stop), keyEquivalent: "")
            stopItem.target = self
            item.menu = menu
            statusItem = item
            return ["token": token, "width": configuration.width, "height": configuration.height]
        }
        guard let token, body["token"] == token else { throw ShareError.message("Window sharing has ended.") }
        if action == "end" { stop(); return true }
        guard action == "frame", !busy, let filter, let configuration else {
            throw ShareError.message("A window frame is not available.")
        }
        busy = true
        defer { busy = false }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard self.token == token, enabled else { throw ShareError.message("Window sharing has ended.") }
        let data = await Task.detached(priority: .userInitiated) {
            NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        }.value
        guard self.token == token, enabled else { throw ShareError.message("Window sharing has ended.") }
        guard let data else {
            throw ShareError.message("The window frame could not be encoded.")
        }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    private enum ShareError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): text }
        }
    }
}

/// Shared popup configurations need one handler, routed by WebKit's webView identity.
@MainActor private final class WindowShareDispatcher: NSObject, WKScriptMessageHandlerWithReply {
    private static var associationKey: UInt8 = 0
    private weak var controller: WKUserContentController?
    let clients = NSMapTable<WKWebView, WindowScreenSharing>(keyOptions: .weakMemory, valueOptions: .weakMemory)

    static func shared(for controller: WKUserContentController) -> WindowShareDispatcher {
        if let existing = objc_getAssociatedObject(controller, &associationKey) as? WindowShareDispatcher { return existing }
        let dispatcher = WindowShareDispatcher()
        dispatcher.controller = controller
        controller.addScriptMessageHandler(dispatcher, contentWorld: .page, name: "oasisWindowShare")
        objc_setAssociatedObject(controller, &associationKey, dispatcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return dispatcher
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let webView = message.webView, let client = clients.object(forKey: webView) else {
            replyHandler(nil, "The browser tab is closed."); return
        }
        Task { @MainActor in
            do { replyHandler(try await client.receive(message), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    func remove(_ webView: WKWebView) {
        clients.removeObject(forKey: webView)
        guard clients.keyEnumerator().allObjects.isEmpty, let controller else { return }
        controller.removeScriptMessageHandler(forName: "oasisWindowShare", contentWorld: .page)
        objc_setAssociatedObject(controller, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
