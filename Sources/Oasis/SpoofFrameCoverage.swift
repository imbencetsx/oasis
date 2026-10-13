import WebKit

/// Frame identities come from WebKit in an isolated world, not page-supplied URLs.
/// Keep registration active while off so enabling also reaches existing cross-origin frames.
@MainActor final class SpoofFrameCoverage: NSObject, WKScriptMessageHandler {
    private let name = "oasisFrames" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let world = WKContentWorld.world(name: "Oasis frame coverage")
    private weak var webView: WKWebView?
    private var frames: [String: WKFrameInfo] = [:]
    private var enabled = false
    private var registrationSource = ""

    func prepare(_ controller: WKUserContentController) {
        registrationSource = """
        (() => {
          const token = Date.now().toString(36) + Math.random().toString(36);
          const report = () => window.webkit?.messageHandlers?.\(name)?.postMessage({token, alive: true});
          addEventListener('pagehide', () => window.webkit?.messageHandlers?.\(name)?.postMessage({token, alive: false}), true);
          report();
          addEventListener('pageshow', report, true);
        })();
        """
        controller.add(self, contentWorld: world, name: name)
        controller.addUserScript(WKUserScript(source: registrationSource,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
    }

    func attach(_ webView: WKWebView, enabled: Bool) {
        self.webView = webView
        self.enabled = enabled
    }

    func apply(enabled: Bool) {
        self.enabled = enabled
        for (token, frame) in frames { apply(to: frame, token: token) }
    }

    private func apply(to frame: WKFrameInfo, token: String) {
        webView?.evaluateJavaScript(enabled ? SpoofMode.source : SpoofMode.restoreSource,
                                   in: frame, in: .page) { [weak self] result in
            if case .failure = result, let self, self.frames[token] === frame {
                self.frames.removeValue(forKey: token)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, let body = message.body as? [String: Any],
              let token = body["token"] as? String else { return }
        if body["alive"] as? Bool == false { frames.removeValue(forKey: token); return }
        frames[token] = message.frameInfo
        apply(to: message.frameInfo, token: token)
    }

    func close() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeScriptMessageHandler(forName: name, contentWorld: world)
        let preserved = controller.userScripts.filter { $0.source != registrationSource }
        controller.removeAllUserScripts()
        for script in preserved { controller.addUserScript(script) }
        frames.removeAll()
        webView = nil
    }
}
