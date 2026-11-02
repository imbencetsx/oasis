import AppKit
import WebKit

/// Captures one tab's page independently of the selected tab and browser chrome.
@MainActor final class WebViewCaptureSource {
    let framing: WebViewCaptureFraming
    private let webView: WKWebView
    private let initialViewSize: CGSize
    private let initialViewportSize: CGSize
    private let displayScale: CGFloat
    private var backgroundWindow: NSWindow?

    init(webView: WKWebView) throws {
        let rect = Self.viewportRect(webView)
        guard rect.width >= 2, rect.height >= 2 else { throw CaptureError.unavailable }
        self.webView = webView
        initialViewSize = webView.bounds.size
        initialViewportSize = rect.size
        displayScale = webView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        framing = WebViewCaptureFraming(contentSize: rect.size)
    }

    func frame() async throws -> CGImage {
        if webView.window == nil { hostInBackground() }
        var rect = Self.viewportRect(webView)
        rect.size.width = min(rect.width, initialViewportSize.width)
        rect.size.height = min(rect.height, initialViewportSize.height)
        guard rect.width >= 2, rect.height >= 2 else { throw CaptureError.unavailable }
        let output = framing.scaledSourceSize(rect.size)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(output.width / displayScale))
        // Waiting for a visible-screen update can stall a background tab/Space.
        configuration.afterScreenUpdates = false
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let fixed = framing.imageOnFixedCanvas(image, sourceSize: output) else {
            throw CaptureError.unavailable
        }
        return fixed
    }

    /// SwiftUI is about to put this same WKWebView back into the visible viewport.
    func prepareForDisplay() {
        guard let backgroundWindow else { return }
        if backgroundWindow.contentView === webView {
            webView.removeFromSuperview()
            backgroundWindow.contentView = nil
        }
        backgroundWindow.close()
        self.backgroundWindow = nil
    }

    func close() { prepareForDisplay() }

    private func hostInBackground() {
        let window = backgroundWindow ?? NSWindow(
            contentRect: NSRect(origin: .zero, size: initialViewSize),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.tabbingMode = .disallowed
        window.hasShadow = false
        webView.removeFromSuperview()
        webView.frame = NSRect(origin: .zero, size: initialViewSize)
        window.contentView = webView
        // This host is never ordered onscreen; it only keeps WebKit attached.
        backgroundWindow = window
    }

    private static func viewportRect(_ webView: WKWebView) -> CGRect {
        let insets = webView.obscuredContentInsets
        return CGRect(x: webView.bounds.minX + insets.left,
                      y: webView.bounds.minY + insets.top,
                      width: max(0, webView.bounds.width - insets.left - insets.right),
                      height: max(0, webView.bounds.height - insets.top - insets.bottom))
    }

    private enum CaptureError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The shared tab's page is not available yet." }
    }
}
