import ObjectiveC
import WebKit

/// Frame identities come from WebKit in an isolated world, not page-supplied URLs.
@MainActor final class SpoofFrameCoverage {
    private weak var webView: WKWebView?
    private var dispatcher: SpoofFrameDispatcher?
    private var frames: [String: WKFrameInfo] = [:]
    private var enabled = false

    func prepare(_ controller: WKUserContentController) {
        dispatcher = SpoofFrameDispatcher.shared(for: controller)
    }

    func attach(_ webView: WKWebView, enabled: Bool) {
        self.webView = webView
        self.enabled = enabled
        dispatcher?.clients.setObject(self, forKey: webView)
    }

    func apply(enabled: Bool) {
        self.enabled = enabled
        for (token, frame) in frames { apply(to: frame, token: token) }
    }

    private func apply(to frame: WKFrameInfo, token: String) {
        webView?.evaluateJavaScript(enabled ? SpoofMode.frameSource : SpoofMode.frameRestoreSource,
                                   in: frame, in: .page) { [weak self] result in
            if case .failure = result, let self, self.frames[token] === frame {
                self.frames.removeValue(forKey: token)
            }
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let token = body["token"] as? String else { return }
        if body["alive"] as? Bool == false { frames.removeValue(forKey: token); return }
        let isNew = frames[token] == nil
        frames[token] = message.frameInfo
        // Fresh disabled documents have nothing to restore. Only cached documents
        // need reconciliation when they return without document-start injection.
        if body["cached"] as? Bool == true { apply(to: message.frameInfo, token: token) }
        else if isNew && enabled {
            webView?.evaluateJavaScript("window['\(SpoofMode.stateKey)']?.version === \(SpoofMode.version)", in: message.frameInfo, in: .page) { [weak self] result in
                guard let self, self.enabled, self.frames[token] === message.frameInfo else { return }
                if case .success(let value) = result, value as? Bool == true { return }
                self.apply(to: message.frameInfo, token: token)
            }
        }
    }

    func refreshCachedFrames() {
        if let webView { dispatcher?.refresh(webView) }
    }

    func close() {
        if let webView { dispatcher?.remove(webView) }
        frames.removeAll()
        dispatcher = nil
        webView = nil
    }
}

/// Popup configurations share a user-content controller with their opener.
/// Install one tracker per controller and route messages by their native web view.
@MainActor private final class SpoofFrameDispatcher: NSObject, WKScriptMessageHandler {
    private static var associationKey: UInt8 = 0
    private static let name = "oasisFrames"
    private static let world = WKContentWorld.world(name: "Oasis frame coverage")
    private static let source = """
        (() => {
          const token = Date.now().toString(36) + Math.random().toString(36);
          const send = body => window.webkit?.messageHandlers?.oasisFrames?.postMessage({token, ...body});
          const refresh = () => {
            send({alive: true, cached: true});
            for (let i=0;i<frames.length;i++) frames[i].postMessage({oasisFrameRefresh: true}, '*');
          };
          globalThis.__oasisRefreshFrames = refresh;
          addEventListener('message', event => {
            if (event.source === parent && event.data?.oasisFrameRefresh === true) refresh();
          }, true);
          addEventListener('pagehide', () => send({alive: false}), true);
          send({alive: true, cached: false});
          addEventListener('pageshow', event => {
            if (event.persisted) send({alive: true, cached: true});
          }, true);
        })();
        """
    private weak var controller: WKUserContentController?
    let clients = NSMapTable<WKWebView, SpoofFrameCoverage>(keyOptions: .weakMemory, valueOptions: .weakMemory)

    static func shared(for controller: WKUserContentController) -> SpoofFrameDispatcher {
        if let existing = objc_getAssociatedObject(controller, &associationKey) as? SpoofFrameDispatcher { return existing }
        let dispatcher = SpoofFrameDispatcher()
        dispatcher.controller = controller
        controller.add(dispatcher, contentWorld: world, name: name)
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        objc_setAssociatedObject(controller, &associationKey, dispatcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return dispatcher
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        clients.object(forKey: webView)?.receive(message)
    }

    func refresh(_ webView: WKWebView) {
        webView.evaluateJavaScript("globalThis.__oasisRefreshFrames?.();", in: nil, in: Self.world) { _ in }
    }

    func remove(_ webView: WKWebView) {
        clients.removeObject(forKey: webView)
        guard clients.keyEnumerator().allObjects.isEmpty, let controller else { return }
        controller.removeScriptMessageHandler(forName: Self.name, contentWorld: Self.world)
        let preserved = controller.userScripts.filter { $0.source != Self.source }
        controller.removeAllUserScripts()
        for script in preserved { controller.addUserScript(script) }
        objc_setAssociatedObject(controller, &Self.associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
