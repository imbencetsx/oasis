import AppKit
import Testing
import WebKit
@testable import Oasis

// SwiftPM's test runner has no foreground application to make a window key.
@MainActor private final class TypingTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@Suite("Clipboard typing", .serialized)
@MainActor struct ClipboardTypingTests {
    @Test func clipboardTextNeverContainsEnterTabOrControlCharacters() {
        #expect(ClipboardTyping.plainText("one\r\ntwo\nthree\rfour\tfive\u{2028}six") == "one two three four five six")
        #expect(ClipboardTyping.plainText("hi\u{0}\u{8}\u{1B}\u{7F}!") == "hi!")
        #expect(ClipboardTyping.plainText("👩‍💻 café") == "👩‍💻 café")
    }

    @Test func speedMultiplierScalesEveryPause() {
        #expect(ClipboardTypingSpeed.scaledDelay(milliseconds: 100, multiplier: 1) == .milliseconds(100))
        #expect(ClipboardTypingSpeed.scaledDelay(milliseconds: 100, multiplier: 10) == .milliseconds(10))
        #expect(ClipboardTypingSpeed.scaledDelay(milliseconds: 100, multiplier: 0.1) == .seconds(1))
        #expect(ClipboardTypingSpeed.scaledDelay(milliseconds: 240, multiplier: 10) == .milliseconds(24))
    }

    @Test func savedSpeedDefaultsAndResetsToOne() throws {
        let suite = "ClipboardTypingSpeedTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ClipboardTypingSpeed.savedMultiplier(in: defaults) == 1)
        defaults.set(2.5, forKey: ClipboardTypingSpeed.preferenceKey)
        #expect(ClipboardTypingSpeed.savedMultiplier(in: defaults) == 2.5)
        defaults.set(ClipboardTypingSpeed.defaultMultiplier, forKey: ClipboardTypingSpeed.preferenceKey)
        #expect(ClipboardTypingSpeed.savedMultiplier(in: defaults) == 1)
        #expect(ClipboardTypingSpeed.normalized(.nan) == 1)
        #expect(ClipboardTypingSpeed.normalized(-10) == 1)
        #expect(ClipboardTypingSpeed.normalized(100) == 10)
        #expect(ClipboardTypingSpeed.normalized(0.01) == 0.1)
    }

    private func fixture() async throws -> (NSWindow, WKWebView) {
        let window = TypingTestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        window.contentView = webView
        webView.loadHTMLString("""
            <!doctype html><title>Typing fixture</title>
            <input id="input" value="old"><textarea id="textarea"></textarea>
            <div id="editable" contenteditable="true"></div>
            <iframe srcdoc="<textarea id='frameInput'></textarea>"></iframe>
            <script>
            window.pastes = 0; window.inputs = 0; window.inputTimes = [];
            document.addEventListener('paste', e => { pastes++; e.preventDefault(); });
            document.addEventListener('input', () => { inputs++; inputTimes.push(performance.now()); });
            </script>
            """, baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if webView.title == "Typing fixture" && !webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(webView.title == "Typing fixture")
        window.makeFirstResponder(webView)
        try #require(window.isKeyWindow)
        try #require(window.firstResponder is NSTextInputClient)
        return (window, webView)
    }

    private func waitUntilFinished(_ typer: ClipboardTyping) async throws {
        for _ in 0..<200 {
            if !typer.isTyping { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Clipboard typing did not finish")
    }

    @Test(arguments: ["input", "textarea", "editable", "frameInput"])
    func typesUnicodeThroughNativeInput(field: String) async throws {
        let (window, webView) = try await fixture()
        let typer = ClipboardTyping()
        defer { typer.stop(); window.close() }
        _ = try await webView.callAsyncJavaScript("""
            const d = field === 'frameInput' ? frames[0].document : document;
            const element = d.getElementById(field);
            element.focus();
            if (element.select) element.select();
            """, arguments: ["field": field], in: nil, contentWorld: .page)
        let text = field == "input" ? "Hi 👋 café" : "Hi 👋 café\nLine 2"
        typer.start(text: text, in: window, spoofModeEnabled: true, speedMultiplier: 1)
        try await waitUntilFinished(typer)
        let value = try await webView.callAsyncJavaScript("""
            const d = field === 'frameInput' ? frames[0].document : document;
            const element = d.getElementById(field);
            return element.value ?? element.innerText;
            """, arguments: ["field": field], in: nil, contentWorld: .page) as? String
        #expect(value == ClipboardTyping.plainText(text))
        #expect(try await webView.evaluateJavaScript("pastes") as? Int == 0)
        if field != "frameInput" {
            #expect(try await webView.evaluateJavaScript("inputs") as? Int == text.count)
            let spacedOut = try await webView.evaluateJavaScript("""
                inputTimes.length > 1 &&
                  inputTimes[inputTimes.length - 1] - inputTimes[0] >= 25 * (inputTimes.length - 1)
                """) as? Bool
            #expect(spacedOut == true)
        }
    }

    @Test func doesNotTypeWhenSpoofModeIsOff() async throws {
        let (window, webView) = try await fixture()
        let typer = ClipboardTyping()
        defer { typer.stop(); window.close() }
        _ = try await webView.evaluateJavaScript("textarea.focus()")
        typer.start(text: "clipboard text", in: window, spoofModeEnabled: false)
        #expect(!typer.isTyping)
        #expect(try await webView.evaluateJavaScript("textarea.value") as? String == "")
        #expect(try await webView.evaluateJavaScript("inputs") as? Int == 0)
    }

    @Test func stopsWhenWebsiteMovesFocus() async throws {
        let (window, webView) = try await fixture()
        let typer = ClipboardTyping()
        defer { typer.stop(); window.close() }
        _ = try await webView.evaluateJavaScript("""
            input.value = ''; input.focus();
            input.addEventListener('input', () => textarea.focus(), { once: true });
            """)
        typer.start(text: "abcdef", in: window, spoofModeEnabled: true, speedMultiplier: 1)
        try await waitUntilFinished(typer)
        #expect(try await webView.evaluateJavaScript("input.value") as? String == "a")
        #expect(try await webView.evaluateJavaScript("textarea.value") as? String == "")
    }

    @Test func cancellationStopsRemainingCharacters() async throws {
        let (window, webView) = try await fixture()
        let typer = ClipboardTyping()
        defer { typer.stop(); window.close() }
        _ = try await webView.evaluateJavaScript("textarea.focus()")
        typer.start(text: String(repeating: "a", count: 200), in: window, spoofModeEnabled: true, speedMultiplier: 1)
        for _ in 0..<100 {
            if (try await webView.evaluateJavaScript("textarea.value.length") as? Int ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        typer.stop()
        let before = try await webView.evaluateJavaScript("textarea.value") as? String
        try await Task.sleep(for: .milliseconds(100))
        let after = try await webView.evaluateJavaScript("textarea.value") as? String
        #expect(before == after)
        #expect((after?.count ?? 0) > 0 && (after?.count ?? 0) < 200)
    }
}
