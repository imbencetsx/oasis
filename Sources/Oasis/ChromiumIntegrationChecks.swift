#if DEBUG
import AppKit
import CefKit

/// Runs against the actual bundled engine, not the WebKit compatibility tests.
@MainActor enum ChromiumIntegrationChecks {
    /// Set OASIS_CHROMIUM_CHECKS to a page URL to open it, run the checks and quit.
    /// The report is written to OASIS_CHROMIUM_CHECKS_OUTPUT (or the temporary directory).
    static func runFromEnvironmentIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let value = environment["OASIS_CHROMIUM_CHECKS"], let url = URL(string: value) else { return }
        Task { @MainActor in
            var session: BrowserSession?
            for _ in 0..<200 {
                session = BrowserLibrary.shared.anySession
                if session != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let session else { NSApp.terminate(nil); return }
            let tab = session.newTab(url: url)
            for _ in 0..<300 {
                if tab.chromium?.browser != nil, !tab.isLoading, tab.url?.absoluteString.hasPrefix(value) == true { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(500))
            await run(session: session)
            NSApp.terminate(nil)
        }
    }

    /// Viewport and input changes reach the renderer asynchronously.
    private static func settle(_ engine: ChromiumTabEngine, _ expression: String) async -> Bool {
        for _ in 0..<40 {
            if (try? await engine.evaluate(expression)) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Where the page's content lies inside one screencast frame.
    static func screencastExtent(_ engine: ChromiumTabEngine, maxWidth: Int = 4000, maxHeight: Int = 4000) async
        -> (frame: CGSize, page: CGSize, description: String) {
        guard let browser = engine.browser else { return (.zero, .zero, "no browser") }
        _ = try? await engine.evaluate("(() => { const m = document.createElement('div'); m.id = '__oasisCorner'; m.style.cssText = 'position:fixed;right:0;bottom:0;width:200px;height:200px;background:rgb(255,0,0);z-index:2147483647'; document.documentElement.append(m); return 0; })()")
        try? await Task.sleep(for: .milliseconds(200))
        var frame: [String: Any]?
        engine.sharing.frameObserver = { frame = $0 }
        _ = try? await browser.devTools("Page.startScreencast", params: ["format": "png", "maxWidth": maxWidth, "maxHeight": maxHeight, "everyNthFrame": 1])
        for _ in 0..<50 where frame == nil { try? await Task.sleep(for: .milliseconds(100)) }
        engine.sharing.frameObserver = nil
        _ = try? await browser.devTools("Page.stopScreencast")
        _ = try? await engine.evaluate("document.getElementById('__oasisCorner')?.remove(); 0")
        guard let frame, let text = frame["data"] as? String, let data = Data(base64Encoded: text),
              let bitmap = NSBitmapImageRep(data: data) else { return (.zero, .zero, "no frame") }
        func red(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > 0.8 && c.greenComponent < 0.3
        }
        let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
        // The marker's bottom-right corner shows how much of the frame the page fills.
        var redWidth = 0, redHeight = 0
        for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) where red(x, y) {
            redWidth = max(redWidth, x + 1); redHeight = max(redHeight, y + 1) } }
        let meta = (frame["metadata"] as? [String: Any]).map { "\($0)" } ?? ""
        return (CGSize(width: w, height: h), CGSize(width: redWidth, height: redHeight),
                "image=\(w)x\(h) page=\(redWidth)x\(redHeight) view=\(browser.nativeView?.frame ?? .zero) meta=\(meta)")
    }

    /// Shares the tab, enters and leaves window fullscreen, and checks that every
    /// delivered frame frames the page identically (no zoom steps in the cast).
    static func fullscreenTransitionFrames(_ engine: ChromiumTabEngine) async throws -> (seamless: Bool, detail: String) {
        guard let window = engine.host.window else { return (false, "no window") }
        ShareConsent.automaticAnswer = ShareChoice(display: nil, surface: "monitor")
        defer { ShareConsent.automaticAnswer = nil }
        _ = try await engine.evaluate("(() => { const m = document.createElement('div'); m.id = '__oasisCorner'; m.style.cssText = 'position:fixed;right:0;bottom:0;width:200px;height:200px;background:rgb(255,0,0);z-index:2147483647'; document.documentElement.append(m); const a = document.createElement('div'); a.id = '__oasisSpin'; a.style.cssText = 'position:fixed;left:40%;top:40%;width:60px;height:60px;background:rgb(0,0,255)'; document.documentElement.append(a); let t = 0; (function tick() { if (!a.isConnected) return; a.style.transform = 'rotate(' + (t += 7) + 'deg)'; requestAnimationFrame(tick); })(); return 0; })()")
        defer { engine.execute("document.getElementById('__oasisCorner')?.remove(); document.getElementById('__oasisSpin')?.remove()") }
        let start = Date()
        var trace: [String] = []
        let stamp = { String(format: "%.3f", Date().timeIntervalSince(start)) }
        engine.sharing.traceLog = { trace.append("\(stamp()) \($0)") }
        engine.sharing.frameObserver = { params in
            let meta = params["metadata"] as? [String: Any] ?? [:]
            trace.append("\(stamp()) frame swap=\(String(format: "%.3f", ((meta["timestamp"] as? Double) ?? 0) - start.timeIntervalSince1970)) held=\(engine.sharing.isHoldingFrames) view=\(engine.browser?.nativeView?.frame.size ?? .zero) dev=\(meta["deviceWidth"] ?? "")x\(meta["deviceHeight"] ?? "") crop=\(engine.captureCrop.width)")
        }
        defer { engine.sharing.frameObserver = nil; engine.sharing.traceLog = nil }
        let begin = try await engine.sharing.receive(["action": "begin"], enabled: true) as? [String: Any]
        guard let token = begin?["token"] as? String, let lock = engine.lockedResolution else { return (false, "share did not begin") }
        defer { engine.sharing.stop() }
        let expectedLeft = (lock.width - 200) / lock.width, expectedTop = (lock.height - 200) / lock.height
        var frames = 0, bad: [String] = []
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                if let result = try? await engine.sharing.receive(["action": "frame", "token": token], enabled: true) as? [String: Any],
                   let image = result["image"] as? String, let comma = image.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(image[image.index(after: comma)...])),
                   let bitmap = NSBitmapImageRep(data: data) {
                    let crop = result["crop"] as? [Double] ?? [1, 1]
                    let w = Double(bitmap.pixelsWide) * crop[0], h = Double(bitmap.pixelsHigh) * crop[1]
                    func red(_ fx: Double, _ fy: Double) -> Bool {
                        guard let c = bitmap.colorAt(x: min(bitmap.pixelsWide - 1, Int(fx * w)), y: min(bitmap.pixelsHigh - 1, Int(fy * h)))?
                            .usingColorSpace(.sRGB) else { return false }
                        return c.redComponent > 0.75 && c.greenComponent < 0.35 && c.blueComponent < 0.35
                    }
                    frames += 1
                    // Inside the marker near its edges, and outside just beyond them.
                    let ok = red(expectedLeft + 0.01, expectedTop + 0.01) && red(0.995, 0.995) &&
                        !red(expectedLeft - 0.02, expectedTop + 0.05) && !red(expectedLeft + 0.05, expectedTop - 0.03)
                    if !ok { bad.append("crop=\(crop) size=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)") }
                    var extent = ""
                    if !ok {
                        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
                        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) { for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                            if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.75, c.greenComponent < 0.35, c.blueComponent < 0.35 {
                                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) } } }
                        extent = " red=\(minX)...\(maxX)x\(minY)...\(maxY)"
                    }
                    trace.append("\(stamp()) DELIVERED ok=\(ok) size=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh) crop=\(crop[0])\(extent)")
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        try await Task.sleep(for: .milliseconds(800))
        let startedFullscreen = window.styleMask.contains(.fullScreen)
        for _ in 0..<2 {
            window.toggleFullScreen(nil)
            try await Task.sleep(for: .milliseconds(2500))
            if window.styleMask.contains(.fullScreen) { titlebarButtonsInFullscreen = titlebarButtonsReady(window) }
        }
        poller.cancel()
        _ = await poller.value
        // Two toggles return the window to where it started.
        let fullscreen = window.styleMask.contains(.fullScreen) != startedFullscreen
        try? trace.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "oasis-transition-trace.txt", atomically: true, encoding: .utf8)
        if let path = ProcessInfo.processInfo.environment["OASIS_CHROMIUM_CHECKS_OUTPUT"] {
            try? trace.joined(separator: "\n").write(toFile: path + ".trace.txt", atomically: true, encoding: .utf8)
        }
        return (frames >= 3 && bad.isEmpty && !fullscreen, "frames=\(frames) bad=\(bad.count) \(bad.prefix(3))")
    }

    /// In fullscreen, the system title bar (shown at the top edge) needs its
    /// close, minimize and exit-fullscreen buttons in their normal places.
    static var titlebarButtonsInFullscreen: String?
    static func titlebarButtonsReady(_ window: NSWindow) -> String {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0) }
        let states = buttons.map { button -> String in
            guard let button else { return "missing" }
            let offset = button.layer?.transform.m41 ?? 0
            return button.isHidden || button.alphaValue < 0.9 || abs(offset) > 0.5 || button.frame.minX < 0 ? "bad(\(button.isHidden),\(button.alphaValue),\(offset),\(button.frame.minX))" : "ok"
        }
        return states.joined(separator: ",")
    }

    /// Shares the main display through the page bridge and checks real frames arrive.
    static func entireScreenShare(_ engine: ChromiumTabEngine) async -> (ok: Bool, detail: String) {
        guard let display = DisplayCapture.displays.first else { return (false, "no display") }
        ShareConsent.automaticAnswer = ShareChoice(display: display.id, surface: "monitor")
        defer { ShareConsent.automaticAnswer = nil; engine.sharing.stop() }
        do {
            guard let begin = try await engine.sharing.receive(["action": "begin"], enabled: true) as? [String: Any],
                  let token = begin["token"] as? String, let width = begin["width"] as? Int, let height = begin["height"] as? Int else {
                return (false, "no begin reply")
            }
            var frames = 0, size = ""
            for _ in 0..<40 {
                if let result = try await engine.sharing.receive(["action": "frame", "token": token], enabled: true) as? [String: Any],
                   let image = result["image"] as? String, let comma = image.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(image[image.index(after: comma)...])), let bitmap = NSBitmapImageRep(data: data) {
                    frames += 1
                    size = "\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return (frames >= 3 && size == "\(width)x\(height)", "frames=\(frames) size=\(size) announced=\(width)x\(height) preflight=\(CGPreflightScreenCaptureAccess())")
        } catch { return (false, "\(error.localizedDescription) preflight=\(CGPreflightScreenCaptureAccess())") }
    }

    static func run(session: BrowserSession) async {
        guard let tab = session.selectedTab, let engine = tab.chromium, let browser = engine.browser else { return }
        var checks: [String: Bool] = [:]
        var detail = ""
        var diagnostics: [String: String] = [:]
        let originalSpoof = session.library.spoofModeEnabled
        let originalSettings = engine.spoofSettings
        let defaults = SpoofSettings()
        do {
            let version = try await browser.devTools("Browser.getVersion")
            checks["chromiumRuntime"] = (version["product"] as? String)?.contains("156.") == true
            engine.setSpoof(true, settings: defaults); await engine.waitForConfiguration()
            try await Task.sleep(for: .milliseconds(300))
            let lock = engine.lockedResolution ?? .zero
            NSApp.activate(ignoringOtherApps: true)
            engine.host.window?.makeKeyAndOrderFront(nil)
            diagnostics["window"] = "active=\(NSApp.isActive) key=\(engine.host.window?.isKeyWindow == true) visible=\(engine.host.window?.occlusionState.contains(.visible) == true)"
            _ = await settle(engine, "innerWidth === \(Int(lock.width))")
            diagnostics["defaults"] = try await engine.evaluate("""
                JSON.stringify({fs: !!document.fullscreenElement, fse: document.fullscreenEnabled, sw: screen.width, sh: screen.height,
                  iw: innerWidth, ih: innerHeight, ow: outerWidth, oh: outerHeight, cd: screen.colorDepth,
                  dm: matchMedia('(display-mode: fullscreen)').matches, db: matchMedia('(display-mode: browser)').matches,
                  focus: document.hasFocus(), hidden: document.hidden, ua: navigator.userAgent, platform: navigator.platform,
                  vendor: navigator.vendor, uad: navigator.userAgentData && navigator.userAgentData.platform, chrome: typeof window.chrome, uadIn: 'userAgentData' in navigator, secure: isSecureContext,
                  lock: '\(Int(lock.width))x\(Int(lock.height))'})
                """) as? String ?? "nil"
            checks["fullscreenAndGeometry"] = try await engine.evaluate("""
                !!document.fullscreenElement && document.fullscreenEnabled &&
                screen.width === innerWidth && screen.height === innerHeight &&
                screen.width === \(Int(lock.width)) && screen.height === \(Int(lock.height)) &&
                outerHeight === innerHeight && screen.colorDepth === 24 &&
                matchMedia('(display-mode: fullscreen)').matches &&
                !matchMedia('(display-mode: browser)').matches && document.hasFocus() && !document.hidden
                """) as? Bool == true
            checks["letterboxedPageView"] = {
                guard let view = browser.nativeView, lock.width > 0 else { return false }
                let ratio = view.frame.width / max(1, view.frame.height)
                return abs(ratio - lock.width / lock.height) < 0.02
            }()
            checks["browserIdentity"] = try await engine.evaluate("""
                navigator.platform === 'Win32' && navigator.userAgent.includes('Windows NT 10.0') &&
                navigator.userAgent.includes('Chrome/156.') && navigator.vendor === 'Google Inc.' &&
                navigator.userAgentData?.platform === 'Windows' && !!window.chrome
                """) as? Bool == true
            checks["iframeCoverage"] = try await engine.evaluate("""
                (() => { const f = document.createElement('iframe'); document.body.append(f);
                  const w = f.contentWindow; const active = !!w.document.fullscreenElement &&
                    w.screen.height === screen.height && w.document.hasFocus(); f.remove(); return active; })()
                """) as? Bool == true
            checks["crossSiteIframeCoverage"] = try await engine.evaluate("""
                (async () => {
                  const frame = document.querySelector('iframe[data-cross-site]');
                  if (!frame) return true;
                  const reply = new Promise(resolve => {
                    addEventListener('message', event => { if (event.data?.oasisProbe) resolve(event.data); }, {once: true});
                    setTimeout(() => resolve(null), 3000);
                  });
                  frame.contentWindow.postMessage('probe', '*');
                  const data = await reply;
                  return !!data && data.active && data.focused && data.fullscreen && data.platform === 'Win32';
                })()
                """) as? Bool == true
            checks["fullscreenExitHidden"] = try await engine.evaluate("""
                (async () => { await document.exitFullscreen(); return !!document.fullscreenElement; })()
                """) as? Bool == true
            checks["selectionReadersEmpty"] = try await engine.evaluate("""
                (() => { const p = document.createElement('p'); p.textContent = 'Selectable text'; document.body.append(p);
                  const range = document.createRange(); range.selectNodeContents(p);
                  const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
                  const hidden = selection.toString() === '' && selection.rangeCount === 0 && selection.type === 'None';
                  selection.removeAllRanges(); p.remove(); return hidden; })()
                """) as? Bool == true
            // Native keys: typed characters reach a text field; shortcuts and other keys do not.
            _ = try await engine.evaluate("""
                (() => { const input = document.createElement('input'); input.id = '__oasisKeys';
                  document.body.append(input); input.focus(); window.__oasisKeyLog = [];
                  addEventListener('keydown', event => __oasisKeyLog.push(event.key)); })()
                """)
            for (key, text, code) in [("a", "a", 65), ("Escape", "", 27)] {
                var params: [String: Any] = ["type": text.isEmpty ? "rawKeyDown" : "keyDown", "key": key, "windowsVirtualKeyCode": code]
                if !text.isEmpty { params["text"] = text }
                _ = try await browser.devTools("Input.dispatchKeyEvent", params: params)
                _ = try await browser.devTools("Input.dispatchKeyEvent", params: ["type": "keyUp", "key": key, "windowsVirtualKeyCode": code])
            }
            diagnostics["keys"] = try await engine.evaluate("JSON.stringify([__oasisKeyLog, document.getElementById('__oasisKeys').value, document.activeElement?.id])") as? String ?? "nil"
            checks["keyboardFiltering"] = await settle(engine, "__oasisKeyLog.join(',') === 'a' && document.getElementById('__oasisKeys').value === 'a'")
            _ = try? await engine.evaluate("document.getElementById('__oasisKeys')?.remove()")
            var firefox = defaults; firefox.browser = .firefox; firefox.platform = .linux64
            engine.setSpoof(true, settings: firefox); await engine.waitForConfiguration()
            checks["firefoxIdentity"] = try await engine.evaluate("""
                navigator.userAgent.includes('Firefox/135.0') && navigator.userAgent.includes('Linux x86_64') &&
                navigator.platform === 'Linux x86_64' && navigator.vendor === '' &&
                navigator.userAgentData === undefined && window.chrome === undefined
                """) as? Bool == true
            var unlocked = defaults; unlocked.fullscreen = false; unlocked.focusVisibility = false
            engine.setSpoof(true, settings: unlocked); await engine.waitForConfiguration()
            try await Task.sleep(for: .milliseconds(300))
            diagnostics["unlocked"] = try await engine.evaluate("JSON.stringify({fs: !!document.fullscreenElement, own: Object.hasOwn(screen, 'width'), iw: innerWidth, p: navigator.platform})") as? String ?? "nil"
            checks["featureSwitchesApply"] = await settle(engine, """
                !document.fullscreenElement && !Object.hasOwn(screen, 'width') && navigator.platform === 'Win32'
                """)
            engine.setSpoof(true, settings: defaults); await engine.waitForConfiguration()
            _ = await settle(engine, "innerWidth === \(Int(lock.width))")
            // Shared frames are cropped to the page's part of each screencast frame.
            let extent = await screencastExtent(engine)
            diagnostics["screencast"] = extent.description
            let crop = engine.captureCrop
            checks["screencastCropMatchesPage"] = extent.frame.width > 0 && extent.page.width > 0 &&
                abs(extent.page.width / extent.frame.width - crop.width) < 0.01 &&
                abs(extent.page.height / extent.frame.height - crop.height) < 0.01
            let transition = try await fullscreenTransitionFrames(engine)
            checks["fullscreenTransitionSeamless"] = transition.seamless
            diagnostics["transition"] = transition.detail
            diagnostics["titlebarButtons"] = titlebarButtonsInFullscreen ?? "not measured"
            checks["fullscreenTitlebarButtons"] = titlebarButtonsInFullscreen == "ok,ok,ok"
            let screen = await entireScreenShare(engine)
            checks["entireScreenShare"] = screen.ok
            diagnostics["entireScreen"] = screen.detail
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
            await engine.refreshFocusEmulation()
            engine.setSpoof(false, settings: defaults); await engine.waitForConfiguration()
            try await Task.sleep(for: .milliseconds(300))
            checks["restoreNormalAPIs"] = try await engine.evaluate("""
                !document.fullscreenElement && !Object.hasOwn(screen, 'width') &&
                !Object.hasOwn(window, 'fullScreen') && !window.__oasisActivityPrivacy_v2 &&
                !navigator.userAgent.includes('Windows NT')
                """) as? Bool == true
            do {
                _ = try await engine.sharing.receive(["action": "begin"], enabled: false)
                checks["sharingDisabledWithoutSpoof"] = false
            } catch { checks["sharingDisabledWithoutSpoof"] = true }
        } catch { detail = error.localizedDescription }
        engine.setSpoof(originalSpoof, settings: originalSettings); await engine.waitForConfiguration()
        let passed = checks.count >= 20 && checks.values.allSatisfy { $0 } && detail.isEmpty
        let report: [String: Any] = ["passed": passed, "checks": checks, "error": detail, "diagnostics": diagnostics]
        let output = ProcessInfo.processInfo.environment["OASIS_CHROMIUM_CHECKS_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("oasis-chromium-checks.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
        session.notice = passed ? "All Chromium engine checks passed." : "Chromium checks found an issue. See \(output.path)."
    }
}
#endif
