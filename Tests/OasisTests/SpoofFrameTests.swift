import Foundation
import Testing
import WebKit
@testable import Oasis

@Suite("Spoof iframe coverage", .serialized)
@MainActor struct SpoofFrameTests {
    @Test(arguments: [true, false]) func opaqueNestedAndDynamicFramesFollowLiveToggles(initialEnabled: Bool) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let fixture = CrossOriginFixture()
        configuration.setURLSchemeHandler(fixture, forURLScheme: "oasis-fixture")
        let tab = BrowserTab(isPrivate: true, configuration: configuration, spoofModeEnabled: initialEnabled)
        defer { tab.close() }
        // Permit only the test fixture scheme through the test navigation delegate;
        // the production delegate intentionally blocks unknown schemes.
        fixture.tab = tab
        tab.webView.navigationDelegate = fixture
        let probe = """
        window.initialSpoof = document.hasFocus() && !document.hidden && !!window.__oasisActivityPrivacy_v2;
        addEventListener('message', event => {
          if (event.data !== 'probe') return;
          let signals = 0, clicks = 0;
          const element = document.createElement('input');
          const host = document.createElement('div');
          document.body.append(host);
          host.attachShadow({mode: 'closed'}).append(element);
          const types = ['focus','blur','focusin','focusout','pointerenter','pointerleave',
                         'pointerover','pointerout','mouseenter','mouseleave','mouseover',
                         'mouseout','visibilitychange','webkitvisibilitychange'];
          const listener = () => signals++;
          for (const type of types) element.addEventListener(type, listener);
          element.onpointerleave = listener;
          element.addEventListener('click', () => clicks++);
          element.focus(); element.blur();
          for (const type of types) element.dispatchEvent(new Event(type));
          element.click();
          top.postMessage({tag: document.title, active: !!window.__oasisActivityPrivacy_v2,
            visible: !document.hidden && document.visibilityState === 'visible',
            focused: document.hasFocus(), signals, clicks, initial: window.initialSpoof}, '*');
          host.remove();
          for (let i=0;i<frames.length;i++) frames[i].postMessage('probe', '*');
        });
        """
        tab.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: probe, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let nested = "<title>Nested opaque</title><p>Nested</p>"
        let dataURL = "data:text/html;base64," + Data(nested.utf8).base64EncodedString()
        let child = "<title>Sandbox</title><iframe src='\(dataURL)'></iframe>"
        let escaped = child.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
        tab.webView.loadHTMLString("""
            <title>Coverage</title><body>
            <iframe srcdoc="<title>Same origin</title>"></iframe>
            <iframe sandbox="allow-scripts" srcdoc="\(escaped)"></iframe>
            <iframe src="oasis-fixture://other-origin/child"></iframe>
            <script>window.reports=[];addEventListener('message', e => {
              if(e.data?.tag) reports.push(e.data);
            });</script>
            """, baseURL: URL(string: "oasis-fixture://main-origin/"))
        for _ in 0..<100 {
            if tab.webView.title == "Coverage" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(tab.webView.title == "Coverage")
        let inaccessible = try await tab.webView.evaluateJavaScript("document.querySelectorAll('iframe')[2].contentDocument === null") as? Bool
        #expect(inaccessible == true)
        for enabled in [true, false, true, false] {
            tab.setSpoofMode(enabled)
            try await Task.sleep(for: .milliseconds(100))
            _ = try await tab.webView.evaluateJavaScript("reports=[]; for(let i=0;i<frames.length;i++) frames[i].postMessage('probe','*');")
            var reports: [[String: Any]] = []
            for _ in 0..<100 {
                reports = try await tab.webView.evaluateJavaScript("reports") as? [[String: Any]] ?? []
                if reports.count == 4 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(reports.count == 4)
            for report in reports {
                #expect(report["active"] as? Bool == enabled)
                #expect(report["clicks"] as? Int == 1)
                #expect(report["initial"] as? Bool == initialEnabled)
                #expect(enabled ? report["signals"] as? Int == 0 : (report["signals"] as? Int ?? 0) > 0)
                if enabled {
                    #expect(report["visible"] as? Bool == true)
                    #expect(report["focused"] as? Bool == true)
                }
            }
        }
        tab.setSpoofMode(true)
        _ = try await tab.webView.evaluateJavaScript("""
            const dynamic = document.createElement('iframe');
            dynamic.src = '\(dataURL)'; document.body.append(dynamic);
            """)
        try await Task.sleep(for: .milliseconds(250))
        _ = try await tab.webView.evaluateJavaScript("reports=[];frames[3].postMessage('probe','*');")
        for _ in 0..<100 {
            if (try await tab.webView.evaluateJavaScript("reports.length") as? Int) == 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let active = try await tab.webView.evaluateJavaScript("reports[0]?.active && reports[0]?.initial && reports[0]?.signals === 0") as? Bool
        #expect(active == true)
    }

    @Test func listenersRemainRemovableAndPropertyHandlersRestore() async throws {
        let tab = BrowserTab(isPrivate: true, spoofModeEnabled: true)
        defer { tab.close() }
        tab.webView.loadHTMLString("<title>Handlers</title><input id='field'>", baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if tab.webView.title == "Handlers" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let synchronousFrame = try await tab.webView.evaluateJavaScript("""
            (() => {
              const frame = document.createElement('iframe'); document.body.append(frame);
              const child = frame.contentWindow;
              const active = child.document.hasFocus() && !child.document.hidden && !!child.__oasisActivityPrivacy_v2;
              frame.remove(); return active;
            })()
            """) as? Bool
        #expect(synchronousFrame == true)
        _ = try await tab.webView.evaluateJavaScript("""
            window.count=0;window.listener=()=>count++;
            field.addEventListener('pointerleave', listener);
            field.onblur=listener;void 0;
            """)
        tab.setSpoofMode(false)
        let restored = try await tab.webView.evaluateJavaScript("""
            field.removeEventListener('pointerleave', listener);
            field.dispatchEvent(new Event('pointerleave'));
            field.dispatchEvent(new Event('blur'));
            count === 1 && field.onblur === listener
            """) as? Bool
        #expect(restored == true)
    }

    @Test func readdingListenersWhileOffDoesNotDuplicateCallbacks() async throws {
        let tab = BrowserTab(isPrivate: true, spoofModeEnabled: true)
        defer { tab.close() }
        tab.webView.loadHTMLString("<title>Listener identity</title><input id='field'>", baseURL: nil)
        for _ in 0..<100 {
            if tab.webView.title == "Listener identity" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await tab.webView.evaluateJavaScript("window.count=0;window.listener=()=>count++;field.addEventListener('blur',listener);")
        for _ in 0..<3 {
            tab.setSpoofMode(false)
            let count = try await tab.webView.evaluateJavaScript("count=0;field.addEventListener('blur',listener);field.dispatchEvent(new Event('blur'));count") as? Int
            #expect(count == 1)
            tab.setSpoofMode(true)
        }
        tab.setSpoofMode(false)
        let removed = try await tab.webView.evaluateJavaScript("count=0;field.removeEventListener('blur',listener);field.dispatchEvent(new Event('blur'));count") as? Int
        #expect(removed == 0)
    }

    @Test func backForwardNavigationUsesTheCurrentSpoofPreference() async throws {
        let fixture = CrossOriginFixture()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(fixture, forURLScheme: "oasis-fixture")
        let tab = BrowserTab(isPrivate: true, configuration: config, spoofModeEnabled: true)
        fixture.tab = tab
        tab.webView.navigationDelegate = fixture
        defer { tab.close() }
        func waitFor(_ title: String) async throws {
            for _ in 0..<100 {
                if tab.webView.title == title && !tab.webView.isLoading { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(tab.webView.title == title)
            try await Task.sleep(for: .milliseconds(50))
        }
        tab.load(URL(string: "oasis-fixture://pages/first")!)
        try await waitFor("Cached first")
        tab.load(URL(string: "oasis-fixture://pages/second")!)
        try await waitFor("Cached second")
        tab.setSpoofMode(false)
        tab.goBack()
        try await waitFor("Cached first")
        #expect(try await tab.webView.evaluateJavaScript("!!window.__oasisActivityPrivacy_v2") as? Bool == false)
        for _ in 0..<100 {
            _ = try await tab.webView.evaluateJavaScript("frames[0].postMessage('querySpoof','*');")
            if try await tab.webView.evaluateJavaScript("childSpoof") as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await tab.webView.evaluateJavaScript("childSpoof") as? Bool == false)
        tab.setSpoofMode(true)
        tab.goForward()
        try await waitFor("Cached second")
        #expect(try await tab.webView.evaluateJavaScript("document.hasFocus() && !document.hidden && !!window.__oasisActivityPrivacy_v2") as? Bool == true)
        for _ in 0..<100 {
            _ = try await tab.webView.evaluateJavaScript("frames[0].postMessage('querySpoof','*');")
            if try await tab.webView.evaluateJavaScript("childSpoof") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await tab.webView.evaluateJavaScript("childSpoof") as? Bool == true)
    }

    @Test func sharedPopupConfigurationsKeepOneTrackerAndSurviveClosingTheOpener() async throws {
        let first = BrowserTab(isPrivate: true, spoofModeEnabled: true)
        let controller = first.webView.configuration.userContentController
        let second = BrowserTab(isPrivate: true, configuration: first.webView.configuration, spoofModeEnabled: true)
        defer { first.close(); second.close() }
        #expect(second.webView.configuration.userContentController === controller)
        #expect(controller.userScripts.count == 2)
        second.webView.loadHTMLString("<title>Popup</title><iframe srcdoc='<p>Child</p>'></iframe>", baseURL: nil)
        for _ in 0..<100 {
            if second.webView.title == "Popup" && !second.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        first.close()
        #expect(controller.userScripts.count == 2)
        for enabled in [false, true, false] {
            second.setSpoofMode(enabled)
            try await Task.sleep(for: .milliseconds(25))
            let active = try await second.webView.evaluateJavaScript("!!window.__oasisActivityPrivacy_v2 && !!frames[0].__oasisActivityPrivacy_v2") as? Bool
            #expect(active == enabled)
        }
        second.close()
        #expect(controller.userScripts.isEmpty)
    }
}

@MainActor private final class CrossOriginFixture: NSObject, WKURLSchemeHandler, WKNavigationDelegate {
    weak var tab: BrowserTab?
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { tab?.webView(webView, didCommit: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tab?.webView(webView, didFinish: navigation) }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let title = urlSchemeTask.request.url?.lastPathComponent == "child" ? "Cross origin" : "Cached " + (urlSchemeTask.request.url?.lastPathComponent ?? "")
        let content = title == "Cross origin" ? """
            <script>addEventListener('message', e => {
              if(e.data === 'querySpoof') parent.postMessage({active: !!window.__oasisActivityPrivacy_v2}, '*');
            });</script>
            """ : """
            <iframe src='oasis-fixture://child-origin/child'></iframe>
            <script>window.childSpoof=null;addEventListener('message',e=>{
              if(typeof e.data?.active === 'boolean') childSpoof=e.data.active;
            });</script>
            """
        let data = Data("<title>\(title)</title><p>Different origin</p>\(content)".utf8)
        urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
            expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
