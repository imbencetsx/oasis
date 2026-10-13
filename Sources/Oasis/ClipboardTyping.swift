import AppKit
import WebKit

enum ClipboardTypingSpeed {
    static let preferenceKey = "clipboardTypingSpeed"
    static let defaultMultiplier = 1.0
    static let range = 0.1...10.0

    static func normalized(_ multiplier: Double) -> Double {
        guard multiplier.isFinite, multiplier > 0 else { return defaultMultiplier }
        return min(max(multiplier, range.lowerBound), range.upperBound)
    }

    static func savedMultiplier(in defaults: UserDefaults = .standard) -> Double {
        normalized(defaults.object(forKey: preferenceKey) as? Double ?? defaultMultiplier)
    }

    static func scaledDelay(milliseconds: Int, multiplier: Double) -> Duration {
        .seconds(Double(milliseconds) / (1_000 * normalized(multiplier)))
    }
}

@MainActor @Observable
final class ClipboardTyping {
    static let shared = ClipboardTyping()
    private(set) var isTyping = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var eventMonitor: Any?

    func toggle(spoofModeEnabled: Bool) {
        if isTyping { stop(); return }
        guard spoofModeEnabled,
              let text = NSPasteboard.general.string(forType: .string),
              let window = NSApp.keyWindow else { return }
        start(text: text, in: window, spoofModeEnabled: spoofModeEnabled)
    }

    func stop() {
        task?.cancel()
        task = nil
        isTyping = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    func start(text: String, in window: NSWindow, spoofModeEnabled: Bool, speedMultiplier: Double? = nil) {
        stop()
        let text = Self.plainText(text)
        guard spoofModeEnabled, !text.isEmpty, let responder = window.firstResponder,
              responder is NSTextInputClient else { return }
        var view = responder as? NSView
        while let current = view, !(current is WKWebView) { view = current.superview }
        let webView = view as? WKWebView
        let token = UUID().uuidString
        let speed = ClipboardTypingSpeed.normalized(speedMultiplier ?? ClipboardTypingSpeed.savedMultiplier())
        isTyping = true
        // Any manual typing or click cancels the remaining text. Let Command-9
        // reach the menu action so the same shortcut can stop an active run.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let isShortcut = event.type == .keyDown && event.charactersIgnoringModifiers == "9" &&
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if !isShortcut { self?.stop() }
            return event
        }
        task = Task { [weak self, weak window, weak responder, weak webView] in
            defer {
                // A cancelled run must not stop a newer run.
                if !Task.isCancelled { self?.stop() }
            }
            if let webView {
                guard (try? await webView.callAsyncJavaScript(Self.captureFocus,
                    arguments: ["token": token], in: nil, contentWorld: .defaultClient)) as? Bool == true else { return }
            }
            // Iterate grapheme clusters so emoji and combining marks stay intact.
            for character in text {
                guard !Task.isCancelled, let window, window.isKeyWindow,
                      window.firstResponder === responder,
                      let client = responder as? NSTextInputClient else { return }
                if let webView {
                    guard (try? await webView.callAsyncJavaScript(Self.checkFocus,
                        arguments: ["token": token], in: nil, contentWorld: .defaultClient)) as? Bool == true else { return }
                }
                guard !Task.isCancelled, window.isKeyWindow, window.firstResponder === responder else { return }
                // Use the native text input path, never the paste action or DOM value setters.
                client.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                do { try await Task.sleep(for: Self.delay(after: character, speed: speed)) } catch { return }
            }
        }
    }

    static func plainText(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "\t" || character.unicodeScalars.allSatisfy({ CharacterSet.newlines.contains($0) }) {
                result.append(" ")
            } else {
                // Remove control characters, while preserving Unicode text and emoji.
                for scalar in character.unicodeScalars where scalar.value >= 0x20 &&
                    !(0x7F...0x9F).contains(scalar.value) {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    private static func delay(after character: Character, speed: Double) -> Duration {
        let milliseconds: Int
        switch character {
        case ".", ",", "!", "?", ";", ":": milliseconds = .random(in: 90...180)
        case " ": milliseconds = .random(in: 50...110)
        default: milliseconds = .random(in: 30...75)
        }
        // Short occasional pauses break up a uniform rhythm without changing text.
        let pause = Int.random(in: 0..<24) == 0 ? Int.random(in: 50...120) : 0
        return ClipboardTypingSpeed.scaledDelay(milliseconds: milliseconds + pause, multiplier: speed)
    }

    private static let captureFocus = """
        const path = [];
        let d = document;
        while (d) {
          const element = d.activeElement;
          if (!element) return false;
          path.push({ document: d, element });
          if (element.tagName !== 'IFRAME' && element.tagName !== 'FRAME') break;
          try { d = element.contentDocument; } catch (_) { d = null; }
        }
        const target = path[path.length - 1].element;
        const editable = target.isContentEditable ||
          ((target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') && !target.disabled && !target.readOnly);
        // Cross-origin frames still receive native text input, with click/key cancellation.
        if (!editable && target.tagName !== 'IFRAME' && target.tagName !== 'FRAME') return false;
        globalThis.__oasisClipboardTyping = { token, path };
        return true;
        """

    private static let checkFocus = """
        const state = globalThis.__oasisClipboardTyping;
        return state?.token === token && state.path.every(({ document: d, element }) =>
          element.isConnected && d.activeElement === element && !element.disabled && !element.readOnly);
        """
}
