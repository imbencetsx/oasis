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
    private var cursor: WebViewCaptureCursor?
    private let cursorProvider: @MainActor (WKWebView, CGRect) -> WebViewCaptureCursor?

    init(webView: WKWebView,
         cursorProvider: (@MainActor (WKWebView, CGRect) -> WebViewCaptureCursor?)? = nil) throws {
        let rect = Self.viewportRect(webView)
        guard rect.width >= 2, rect.height >= 2 else { throw CaptureError.unavailable }
        self.webView = webView
        self.cursorProvider = cursorProvider ?? Self.cursorSnapshot
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
        if webView.window !== backgroundWindow {
            cursor = cursorProvider(webView, rect) ?? cursor
        }
        let frameCursor = cursor
        let output = framing.scaledSourceSize(rect.size)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(output.width / displayScale))
        // Waiting for a visible-screen update can stall a background tab/Space.
        configuration.afterScreenUpdates = false
        let snapshot = try await webView.takeSnapshot(configuration: configuration)
        guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let fixed = framing.imageOnFixedCanvas(image, sourceSize: output, cursor: frameCursor) else {
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

    private static func cursorSnapshot(webView: WKWebView, rect: CGRect) -> WebViewCaptureCursor? {
        // Never sample another tab, desktop, or application's pointer. Keeping the
        // previous overlay also preserves its shape when the source loses focus.
        guard NSApp.isActive, let window = webView.window,
              window.isKeyWindow,
              window.isVisible, !window.isMiniaturized, window.isOnActiveSpace,
              !webView.isHiddenOrHasHiddenAncestor else { return nil }
        let point = webView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard rect.contains(point), webView.visibleRect.contains(point),
              let root = window.contentView else { return nil }
        let rootPoint = root.superview?.convert(point, from: webView)
            ?? webView.convert(point, to: nil)
        guard let hit = root.hitTest(rootPoint), hit === webView || hit.isDescendant(of: webView) else { return nil }
        let pointer = NSCursor.current
        guard let image = pointer.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return WebViewCaptureCursor(image: image,
            position: CGPoint(x: point.x - rect.minX,
                              y: webView.isFlipped ? point.y - rect.minY : rect.maxY - point.y),
            hotSpot: pointer.hotSpot, size: pointer.image.size)
    }

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
