import AppKit
import ObjectiveC
import WebKit

/// A Spoof Mode bridge from getDisplayMedia to the requesting tab's own page.
@MainActor final class WindowScreenSharing: NSObject {
    nonisolated static let source = """
        if (w.HTMLCanvasElement.prototype.captureStream) {
          // Scope the metadata to tracks produced by this bridge. Prototype calls
          // and native MediaStream.clone() must see the same identity as direct calls.
          const sharedTracks = new WeakMap();
          const trackProto = w.MediaStreamTrack.prototype;
          const nativeSettings = trackProto.getSettings;
          const nativeCapabilities = trackProto.getCapabilities;
          const nativeConstraints = trackProto.getConstraints;
          const nativeClone = trackProto.clone;
          const nativeStop = trackProto.stop;
          const nativeStreamClone = w.MediaStream.prototype.clone;
          const nativeLabel = Object.getOwnPropertyDescriptor(trackProto, 'label');
          patch(trackProto, 'getSettings', { writable: true, value: function getSettings() {
            const settings = nativeSettings.call(this), sharing = sharedTracks.get(this);
            return sharing ? {...settings, ...sharing.settings} : settings;
          }});
          patch(trackProto, 'getCapabilities', { writable: true, value: function getCapabilities() {
            const capabilities = nativeCapabilities.call(this), sharing = sharedTracks.get(this);
            return sharing ? {...capabilities, displaySurface: 'monitor', logicalSurface: true,
              cursor: ['always'], deviceId: sharing.settings.deviceId} : capabilities;
          }});
          patch(trackProto, 'getConstraints', { writable: true, value: function getConstraints() {
            const constraints = nativeConstraints.call(this);
            return sharedTracks.has(this) ? {...constraints, displaySurface: 'monitor',
              logicalSurface: true, cursor: 'always'} : constraints;
          }});
          if (nativeLabel?.get) patch(trackProto, 'label', { get: function() {
            return sharedTracks.has(this) ? 'Screen 1' : nativeLabel.get.call(this);
          }});
          patch(trackProto, 'clone', { writable: true, value: function clone() {
            const result = nativeClone.call(this), sharing = sharedTracks.get(this);
            if (sharing) sharing.add(result);
            return result;
          }});
          // Native MediaStream.clone() does not call JavaScript track.clone().
          patch(w.MediaStream.prototype, 'clone', { writable: true, value: function clone() {
            const tracks = this.getTracks();
            return tracks.some(track => sharedTracks.has(track))
              ? new w.MediaStream(tracks.map(track => track.clone())) : nativeStreamClone.call(this);
          }});
          patch(trackProto, 'stop', { writable: true, value: function stop() {
            nativeStop.call(this);
            const sharing = sharedTracks.get(this);
            if (sharing) {
              sharing.tracks.delete(this);
              if (!sharing.tracks.size) sharing.finish();
            }
          }});
          let mediaDevices = w.navigator.mediaDevices;
          if (!mediaDevices) {
            mediaDevices = {};
            patch(w.navigator, 'mediaDevices', { get: () => mediaDevices });
          }
          const nativeSupportedConstraints = mediaDevices.getSupportedConstraints;
          patch(mediaDevices, 'getSupportedConstraints', { writable: true, value: function getSupportedConstraints() {
            return {...nativeSupportedConstraints?.call(this), displaySurface: true, logicalSurface: true, cursor: true};
          }});
          patch(mediaDevices, 'getDisplayMedia', { writable: true, value: async function getDisplayMedia(options = {}) {
            if (!w.isSecureContext || w !== w.top)
              throw new w.DOMException('Tab sharing requires an HTTPS top-level page.', 'NotAllowedError');
            if (options.video === false)
              throw new w.TypeError('Tab sharing requires a video track.');
            if (!w.navigator.userActivation?.isActive)
              throw new w.DOMException('Start tab sharing with a click.', 'InvalidStateError');
            const bridge = w.webkit?.messageHandlers?.oasisWindowShare;
            if (!bridge) throw new w.DOMException('Tab sharing is unavailable.', 'NotSupportedError');
            let info;
            try { info = await bridge.postMessage({action: 'begin'}); }
            catch (error) { throw new w.DOMException(String(error), 'NotAllowedError'); }
            const canvas = d.createElement('canvas');
            canvas.width = info.width; canvas.height = info.height;
            const context = canvas.getContext('2d');
            let stream, track, timer, stopped = false;
            const tracks = new Set();
            const finish = () => {
              if (stopped) return;
              stopped = true;
              w.clearTimeout(timer);
              cleanups.delete(finish);
              sharingStops.delete(info.token);
              for (const activeTrack of tracks) {
                nativeStop.call(activeTrack);
                activeTrack.dispatchEvent(new w.Event('ended'));
              }
              tracks.clear();
              bridge.postMessage({action: 'end', token: info.token}).catch(() => {});
              canvas.width = canvas.height = 0;
            };
            cleanups.add(finish);
            sharingStops.set(info.token, finish);
            let cursorImage = null, cursorURL = '';
            let cachedImage = null, cachedCursor = null;
            const drawCursor = () => {
              if (cachedCursor && cursorImage && !stopped) {
                context.drawImage(cursorImage, cachedCursor.x, cachedCursor.y, cachedCursor.width, cachedCursor.height);
              }
            };
            const paint = async () => {
              const frame = await bridge.postMessage({action: 'frame', token: info.token});
              if (stopped) return false;
              if (frame?.ended) { finish(); return false; }
              // WebKit or Chromium can temporarily have no new frame.
              // Keep the canvas's last image and retry smoothly.
              if (frame?.retry) {
                if (cachedImage && !stopped) {
                  context.drawImage(cachedImage, 0, 0, canvas.width, canvas.height);
                  drawCursor();
                  return true;
                }
                return false;
              }
              if (frame?.same) {
                if (cachedImage && !stopped) {
                  context.drawImage(cachedImage, 0, 0, canvas.width, canvas.height);
                }
              } else {
                const image = new w.Image();
                image.src = typeof frame === 'string' ? frame : frame.image;
                await image.decode();
                if (stopped) return false;
                cachedImage = image;
                context.drawImage(image, 0, 0, canvas.width, canvas.height);
              }
              // Overlay cursor
              if (frame?.cursor) {
                cachedCursor = frame.cursor;
                if (cachedCursor.image !== cursorURL) {
                  cursorImage = new w.Image(); cursorImage.src = cachedCursor.image;
                  await cursorImage.decode(); cursorURL = cachedCursor.image;
                }
              }
              drawCursor();
              return !stopped;
            };
            try {
              if (!await paint()) throw new w.DOMException('The initial tab frame is unavailable.', 'AbortError');
              if (stopped) throw new w.DOMException('Tab sharing has ended.', 'AbortError');
              stream = canvas.captureStream(60);
              track = stream.getVideoTracks()[0];
              const sharing = {
                tracks, finish,
                settings: {displaySurface: 'monitor', logicalSurface: true, cursor: 'always',
                  deviceId: w.crypto.randomUUID(), screenPixelRatio: w.devicePixelRatio || 1},
                add(value) { tracks.add(value); sharedTracks.set(value, sharing); }
              };
              sharing.add(track);
              const targetInterval = 1000 / 60;
              const next = async () => {
                const start = w.performance?.now ? w.performance.now() : Date.now();
                try { await paint(); }
                catch (_) { /* A transient bridge/capture/decode error must not end the stream. */ }
                if (!stopped) {
                  const now = w.performance?.now ? w.performance.now() : Date.now();
                  const elapsed = now - start;
                  const delay = Math.max(0, targetInterval - elapsed);
                  timer = w.setTimeout(next, delay);
                }
              };
              timer = w.setTimeout(next, 0);
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
    private var source: WebViewCaptureSource?
    private var statusItem: NSStatusItem?
    private var busy = false
    private var requesting = false
    private var activity: WindowCaptureActivity?

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
        let endingActivity = activity
        activity = nil
        if let token, let webView {
            // Stop the background page's MediaStream before restoring its idle policy.
            webView.evaluateJavaScript("window['\(SpoofMode.stateKey)']?.stopSharing?.('\(token)');") { _, _ in
                endingActivity?.end()
            }
        } else {
            endingActivity?.end()
        }
        token = nil
        source?.close()
        source = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func close() {
        stop()
        if let webView { dispatcher?.remove(webView) }
        webView = nil
        dispatcher = nil
    }

    func prepareForDisplay() { source?.prepareForDisplay() }

    fileprivate func receive(_ message: WKScriptMessage) async throws -> Any {
        guard enabled, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              let body = message.body as? [String: String], let action = body["action"],
              let webView, message.webView === webView else {
            throw ShareError.message("Tab sharing requires an HTTPS top-level page and Spoof Mode.")
        }
        if action == "begin" {
            guard !requesting, token == nil, let window = webView.window,
                  window.attachedSheet == nil else {
                throw ShareError.message("Tab sharing is already active or a dialog is open.")
            }
            requesting = true
            defer { requesting = false }
            let requestGeneration = generation
            let alert = NSAlert()
            alert.messageText = "Share this tab with \(message.frameInfo.securityOrigin.host)?"
            alert.informativeText = "Only this tab's website will be shared, without browser controls. The cursor stays at its last page position when you leave the tab. Opening or switching tabs won't change the shared page. Stop from the Sharing menu in the macOS menu bar. Available only in Spoof Mode."
            alert.addButton(withTitle: "Don't Allow")
            alert.addButton(withTitle: "Share Tab")
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .alertSecondButtonReturn, enabled, generation == requestGeneration else {
                throw ShareError.message("Tab sharing was cancelled.")
            }
            let source = try WebViewCaptureSource(webView: webView)
            self.source = source
            activity = WindowCaptureActivity(preferences: webView.configuration.preferences)
            let token = UUID().uuidString
            self.token = token
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "Sharing"
            item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Sharing website tab")
            let menu = NSMenu()
            menu.addItem(withTitle: "Sharing tab with \(message.frameInfo.securityOrigin.host)", action: nil, keyEquivalent: "")
            let stopItem = menu.addItem(withTitle: "Stop Sharing", action: #selector(stop), keyEquivalent: "")
            stopItem.target = self
            item.menu = menu
            statusItem = item
            return ["token": token, "width": source.framing.width, "height": source.framing.height]
        }
        if action == "frame", token == nil || body["token"] != token { return ["ended": true] }
        guard let token, body["token"] == token else { throw ShareError.message("Tab sharing has ended.") }
        if action == "end" { stop(); return true }
        guard action == "frame", let source else {
            throw ShareError.message("A tab frame is not available.")
        }
        if busy { return ["retry": true] }
        busy = true
        defer { busy = false }
        let image: CGImage
        do {
            image = try await source.frame()
        } catch {
            guard self.token == token, enabled else { return ["ended": true] }
            return ["retry": true]
        }
        guard self.token == token, enabled else { throw ShareError.message("Tab sharing has ended.") }
        let encoded = await Task.detached(priority: .high) {
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
                return nil as String?
            }
            return "data:image/jpeg;base64," + data.base64EncodedString()
        }.value
        guard self.token == token, enabled else { throw ShareError.message("Tab sharing has ended.") }
        guard let encoded else {
            throw ShareError.message("The tab frame could not be encoded.")
        }
        return encoded
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
            if (message.body as? [String: String])?["action"] == "frame" {
                replyHandler(["ended": true], nil); return
            }
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
