import AppKit
import ObjectiveC
import WebKit

/// A Spoof Mode bridge from getDisplayMedia to the requesting tab's own page.
@MainActor final class WindowScreenSharing: NSObject {
    nonisolated static let source = """
        if (w.HTMLCanvasElement.prototype.captureStream) {
          // Scope the metadata to tracks produced by this bridge. Prototype calls
          // and native MediaStream.clone() must see the same identity as direct calls.
          // Tracks outlive a settings change, so their records live on the window.
          if (!Object.hasOwn(w, '__oasisSharedTracks'))
            Object.defineProperty(w, '__oasisSharedTracks', { value: new WeakMap(), configurable: true });
          const sharedTracks = w.__oasisSharedTracks;
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
            return sharing ? {...capabilities, displaySurface: sharing.settings.displaySurface, logicalSurface: true,
              cursor: ['always'], deviceId: sharing.settings.deviceId} : capabilities;
          }});
          patch(trackProto, 'getConstraints', { writable: true, value: function getConstraints() {
            const constraints = nativeConstraints.call(this), sharing = sharedTracks.get(this);
            return sharing ? {...constraints, displaySurface: sharing.settings.displaySurface,
              logicalSurface: true, cursor: 'always'} : constraints;
          }});
          if (nativeLabel?.get) patch(trackProto, 'label', { get: function() {
            return sharedTracks.get(this)?.label ?? nativeLabel.get.call(this);
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
              sharingStops.delete(info.token);
              for (const activeTrack of tracks) {
                nativeStop.call(activeTrack);
                activeTrack.dispatchEvent(new w.Event('ended'));
              }
              tracks.clear();
              bridge.postMessage({action: 'end', token: info.token}).catch(() => {});
              canvas.width = canvas.height = 0;
            };
            sharingStops.set(info.token, finish);
            let cursorImage = null, cursorURL = '';
            let cachedImage = null, cachedCursor = null, cachedCrop = null;
            // A frame can carry the fraction of it the page occupies; draw only that part.
            const drawFrame = () => {
              const [width, height] = cachedCrop ?? [1, 1];
              if (width >= 0.999 && height >= 0.999) {
                context.drawImage(cachedImage, 0, 0, canvas.width, canvas.height);
              } else {
                context.drawImage(cachedImage, 0, 0, cachedImage.naturalWidth * width, cachedImage.naturalHeight * height,
                                  0, 0, canvas.width, canvas.height);
              }
            };
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
                  drawFrame();
                  drawCursor();
                  return true;
                }
                return false;
              }
              if (frame?.same) {
                if (cachedImage && !stopped) drawFrame();
              } else {
                const image = new w.Image();
                image.src = typeof frame === 'string' ? frame : frame.image;
                await image.decode();
                if (stopped) return false;
                cachedImage = image;
                cachedCrop = Array.isArray(frame?.crop) ? frame.crop : null;
                drawFrame();
              }
              // Overlay cursor; without one (cursor containment off and the
              // pointer outside the page) nothing is drawn.
              cachedCursor = frame?.cursor ?? (typeof frame === 'string' ? cachedCursor : null);
              if (cachedCursor && cachedCursor.image !== cursorURL) {
                cursorImage = new w.Image(); cursorImage.src = cachedCursor.image;
                await cursorImage.decode(); cursorURL = cachedCursor.image;
              }
              drawCursor();
              return !stopped;
            };
            try {
              if (!await paint()) throw new w.DOMException('The initial tab frame is unavailable.', 'AbortError');
              if (stopped) throw new w.DOMException('Tab sharing has ended.', 'AbortError');
              stream = canvas.captureStream(60);
              track = stream.getVideoTracks()[0];
              // Spoof Mode reports the share as the surface chosen in the share sheet.
              const surface = info.surface === 'browser' ? 'browser' : 'monitor';
              const sharing = {
                tracks, finish,
                label: surface === 'browser'
                  ? 'web-contents-media-stream://' + Math.floor(Math.random() * 900 + 100) + ':' + Math.floor(Math.random() * 9 + 1)
                  : 'screen:0:0',
                settings: {displaySurface: surface, logicalSurface: true, cursor: 'always',
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
    var isSharing: Bool { token != nil }
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
            let surface = await ShareConsent.ask(host: message.frameInfo.securityOrigin.host, window: window,
                                                 reportAs: true, offersScreens: false)?.surface
            guard let surface, enabled, generation == requestGeneration else {
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
            return ["token": token, "width": source.framing.width, "height": source.framing.height, "surface": surface]
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

/// What the user chose to share, and what the website is told it is.
struct ShareChoice: Sendable, Equatable {
    /// nil shares the requesting tab; otherwise the entire display.
    var display: CGDirectDisplayID?
    /// The reported display surface: "monitor" or "browser".
    var surface: String
}

/// The share confirmation sheet: share this tab or an entire screen and, in
/// Spoof Mode, report it to the website as a full screen or a single tab
/// (Prism's "Report to website as").
@MainActor enum ShareConsent {
    static let reportAsKey = "spoofShareReportAs"

    #if DEBUG
    /// Automated checks answer the sheet without showing it.
    static var automaticAnswer: ShareChoice?
    #endif

    static func ask(host: String, window: NSWindow, reportAs: Bool, offersScreens: Bool) async -> ShareChoice? {
        #if DEBUG
        if let automaticAnswer { return automaticAnswer }
        #endif
        let displays = offersScreens ? DisplayCapture.displays : []
        let alert = NSAlert()
        alert.messageText = "Share with \(host)?"
        alert.informativeText = displays.isEmpty
            ? "Only this tab's website will be shared, without browser controls. Switching tabs won't change the shared page. Stop from the Sharing menu in the macOS menu bar."
            : "This tab shares only its website, without browser controls. Entire screen shares everything on that display, including the pointer, and needs Screen Recording permission. Stop from the Sharing menu in the macOS menu bar."
        alert.addButton(withTitle: "Don't Allow")
        alert.addButton(withTitle: "Share")
        let form = ShareForm(displays: displays, reportAs: reportAs,
                             rememberedSurface: UserDefaults.standard.string(forKey: reportAsKey))
        alert.accessoryView = form.view
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertSecondButtonReturn else { return nil }
        let choice = form.choice
        if reportAs { UserDefaults.standard.set(choice.surface, forKey: reportAsKey) }
        return choice
    }
}

/// The sheet's controls. Report-as follows the shared target until the user
/// picks it explicitly, as in Prism.
@MainActor private final class ShareForm: NSObject {
    let view: NSView
    private let target: NSPopUpButton?
    private let report: NSPopUpButton?
    private let displays: [DisplayCapture.Display]
    private let rememberedSurface: String?
    private var reportChosen = false

    init(displays: [DisplayCapture.Display], reportAs: Bool, rememberedSurface: String?) {
        self.displays = displays
        self.rememberedSurface = rememberedSurface
        var rows: [(String, NSPopUpButton)] = []
        if displays.isEmpty { target = nil } else {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItem(withTitle: "This tab")
            for display in displays {
                popup.addItem(withTitle: displays.count == 1 ? "Entire screen" : "Entire screen — \(display.name)")
            }
            rows.append(("Share:", popup))
            target = popup
        }
        if reportAs {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: ["Full screen", "Single tab"])
            popup.selectItem(at: rememberedSurface == "browser" ? 1 : 0)
            rows.append(("Report to website as:", popup))
            report = popup
        } else { report = nil }
        let width: CGFloat = 320, rowHeight: CGFloat = 30
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * rowHeight))
        for (index, (title, popup)) in rows.enumerated() {
            let y = CGFloat(rows.count - 1 - index) * rowHeight
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: y + 6, width: 146, height: 18)
            popup.frame = NSRect(x: 150, y: y + 1, width: width - 150, height: 26)
            container.addSubview(label); container.addSubview(popup)
        }
        view = container
        super.init()
        target?.target = self; target?.action = #selector(targetChanged)
        report?.target = self; report?.action = #selector(reportChanged)
    }

    @objc private func targetChanged() {
        guard let report, !reportChosen else { return }
        let sharesScreen = (target?.indexOfSelectedItem ?? 0) > 0
        report.selectItem(at: sharesScreen ? 0 : (rememberedSurface == "browser" ? 1 : 0))
    }

    @objc private func reportChanged() { reportChosen = true }

    var choice: ShareChoice {
        let index = target?.indexOfSelectedItem ?? 0
        let display = index > 0 && index <= displays.count ? displays[index - 1].id : nil
        let surface: String
        if let report { surface = report.indexOfSelectedItem == 1 ? "browser" : "monitor" }
        else { surface = display == nil ? "browser" : "monitor" }
        return ShareChoice(display: display, surface: surface)
    }
}
