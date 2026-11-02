import CoreGraphics
import ScreenCaptureKit

/// Keeps window-local coordinates at the same scale and origin for a whole share.
struct WindowCaptureFraming: Sendable {
    let width: Int
    let height: Int
    private let scale: CGFloat
    private let frameSizeOffset: CGSize

    init(contentSize: CGSize, windowSize: CGSize) {
        scale = min(1, 1440 / max(1, contentSize.width))
        width = max(2, Int(contentSize.width * scale))
        height = max(2, Int(contentSize.height * scale))
        frameSizeOffset = CGSize(width: windowSize.width - contentSize.width,
                                 height: windowSize.height - contentSize.height)
    }

    func configuration(windowSize: CGSize) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Request the current window at the original pixel scale. Asking the
        // system to fit every new window size into the original canvas zooms it.
        configuration.width = max(2, Int((windowSize.width - frameSizeOffset.width) * scale))
        configuration.height = max(2, Int((windowSize.height - frameSizeOffset.height) * scale))
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        // Forcing opacity makes WindowServer paint transparent rounded corners white.
        configuration.shouldBeOpaque = false
        configuration.showsCursor = false
        configuration.showMouseClicks = false
        configuration.includeChildWindows = false
        configuration.capturesAudio = false
        return configuration
    }

    func imageOnFixedCanvas(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Continue the window's own top-edge background into unused space and
        // beneath transparent corners, rather than adding contrasting black bars.
        if let background = image.cropping(to: CGRect(x: image.width / 2,
                                                       y: min(8, image.height - 1), width: 1, height: 1)) {
            context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Top-left anchoring avoids recentering as the Dock changes available
        // space. A larger window is cropped; a smaller one gets bottom/right padding.
        context.draw(image, in: CGRect(x: 0, y: height - image.height,
                                      width: image.width, height: image.height))
        return context.makeImage()
    }
}
