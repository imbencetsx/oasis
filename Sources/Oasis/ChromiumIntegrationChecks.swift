#if DEBUG
import AppKit
import CefKit

/// Runs against the actual bundled engine, not the WebKit compatibility tests.
@MainActor enum ChromiumIntegrationChecks {
    static func run(session: BrowserSession) async {
        guard let tab = session.selectedTab, let engine = tab.chromium, let browser = engine.browser else { return }
        var checks: [String: Bool] = [:]
        var detail = ""
        let originalSpoof = session.library.spoofModeEnabled
        do {
            let version = try await browser.devTools("Browser.getVersion")
            checks["chromiumRuntime"] = (version["product"] as? String)?.contains("156.") == true
            engine.setSpoof(true); await engine.waitForConfiguration()
            checks["fullscreenAndGeometry"] = try await engine.evaluate("""
                !!document.fullscreenElement && document.fullscreenEnabled && window.fullScreen &&
                screen.width === innerWidth && screen.height === innerHeight &&
                outerHeight === innerHeight && matchMedia('(display-mode: fullscreen)').matches &&
                !matchMedia('(display-mode: browser)').matches && document.hasFocus() && !document.hidden
                """) as? Bool == true
            checks["browserIdentity"] = try await engine.evaluate("""
                navigator.platform === 'Win32' && navigator.userAgent.includes('Chrome/156.')
                """) as? Bool == true
            checks["iframeCoverage"] = try await engine.evaluate("""
                (() => { const f = document.createElement('iframe'); document.body.append(f);
                  const w = f.contentWindow; const active = !!w.document.fullscreenElement &&
                    w.screen.height === w.innerHeight && w.document.hasFocus(); f.remove(); return active; })()
                """) as? Bool == true
            checks["fullscreenRequestStaysWindowed"] = try await engine.evaluate("""
                (async () => { await document.body.requestFullscreen(); await document.exitFullscreen();
                  return document.fullscreenElement === document.body; })()
                """) as? Bool == true && engine.host.window?.styleMask.contains(.fullScreen) != true
            let before = try await browser.devTools("Page.captureScreenshot", params: ["format": "png", "fromSurface": true])
            checks["pageCapture"] = (before["data"] as? String).flatMap { Data(base64Encoded: $0) } != nil

            // A background tab must still repaint; a frozen last screenshot cannot pass.
            let captureSize = try await engine.beginCaptureViewport()
            _ = try await browser.devTools("Emulation.setFocusEmulationEnabled", params: ["enabled": true])
            let away = session.newTab()
            try await Task.sleep(for: .milliseconds(200))
            _ = try await engine.evaluate("""
                (() => { const m = document.createElement('div'); m.id = '__oasisCaptureTest';
                  m.style.cssText = 'position:fixed;left:8px;top:8px;width:32px;height:32px;background:rgb(255,0,255);z-index:2147483647';
                  document.documentElement.append(m); })()
                """)
            checks["liveBackgroundRepaint"] = false
            for _ in 0..<10 {
                let hidden = try await engine.capturePage()
                let viewportWidth = try await engine.evaluate("innerWidth") as? Double ?? 1
                if let text = hidden["data"] as? String, let data = Data(base64Encoded: text), let bitmap = NSBitmapImageRep(data: data) {
                    let point = max(1, Int(20 * Double(bitmap.pixelsWide) / viewportWidth))
                    let color = bitmap.colorAt(x: point, y: point)?.usingColorSpace(.sRGB)
                    if color.map({ $0.redComponent > $0.greenComponent + 0.4 && $0.blueComponent > $0.greenComponent + 0.4 }) == true {
                        checks["liveBackgroundRepaint"] = true; break
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let backgroundSize = try await engine.evaluate("({width:innerWidth,height:innerHeight})") as? [String: Double]
            checks["backgroundViewportStable"] = backgroundSize?["width"] == captureSize.width && backgroundSize?["height"] == captureSize.height
            _ = try? await engine.evaluate("document.getElementById('__oasisCaptureTest')?.remove()")
            session.closeTab(away.id); session.select(tab.id)
            await engine.endCaptureViewport()
            _ = try await browser.devTools("Emulation.setFocusEmulationEnabled", params: ["enabled": false])
            engine.setSpoof(false); await engine.waitForConfiguration()
            checks["restoreNormalAPIs"] = try await engine.evaluate("""
                !document.fullscreenElement && !Object.hasOwn(screen, 'width') &&
                !Object.hasOwn(window, 'fullScreen') && !window.__oasisActivityPrivacy_v2
                """) as? Bool == true
            do {
                _ = try await engine.sharing.receive(["action": "begin"], enabled: false)
                checks["sharingDisabledWithoutSpoof"] = false
            } catch { checks["sharingDisabledWithoutSpoof"] = true }
        } catch { detail = error.localizedDescription }
        engine.setSpoof(originalSpoof); await engine.waitForConfiguration()
        let passed = checks.count >= 10 && checks.values.allSatisfy { $0 } && detail.isEmpty
        let report: [String: Any] = ["passed": passed, "checks": checks, "error": detail]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("oasis-chromium-checks.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
        session.notice = passed ? "All Chromium engine checks passed." : "Chromium checks found an issue. See \(output.path)."
    }
}
#endif
