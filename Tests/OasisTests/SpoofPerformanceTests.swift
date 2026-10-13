import Foundation
import Testing
import WebKit
@testable import Oasis

@Suite("Spoof performance", .serialized)
@MainActor struct SpoofPerformanceTests {
    @Test func frameReadsAndOrdinaryDOMUpdatesStayCheap() async throws {
        let tab = BrowserTab(isPrivate: true, spoofModeEnabled: true)
        defer { tab.close() }
        tab.webView.loadHTMLString("<title>Performance</title><iframe srcdoc='<p>Frame</p>'></iframe>",
            baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if tab.webView.title == "Performance" && !tab.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(tab.webView.title == "Performance")
        let measurements = try await tab.webView.callAsyncJavaScript("""
            const define = Object.defineProperty;
            const query = Element.prototype.querySelectorAll;
            let writes = 0, scans = 0;
            Object.defineProperty = function(...args) { writes++; return define(...args); };
            Element.prototype.querySelectorAll = function(...args) { scans++; return query.apply(this, args); };
            const frame = document.querySelector('iframe');
            const child = frame.contentWindow;
            const childDefine = child.Object.defineProperty;
            child.Object.defineProperty = function(...args) { writes++; return childDefine(...args); };
            try {
              const frame = document.querySelector('iframe');
              // Warm the frame before measuring repeated access to an installed document.
              void frame.contentWindow;
              writes = 0;
              const start = performance.now();
              for (let i=0;i<1000;i++) void frame.contentWindow;
              const readMS = performance.now() - start;
              const fragment = document.createDocumentFragment();
              for (let i=0;i<1000;i++) {
                const item = document.createElement('div'); item.textContent='Item '+i;
                fragment.append(item);
              }
              document.body.append(fragment);
              await new Promise(resolve => setTimeout(resolve, 0));
              return {writes, scans, readMS};
            } finally {
              child.Object.defineProperty = childDefine;
              Object.defineProperty = define;
              Element.prototype.querySelectorAll = query;
            }
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        print("Spoof hot paths:", measurements ?? [:])
        #expect(measurements?["writes"] as? Int == 0)
        #expect(measurements?["scans"] as? Int == 0)
    }
}
