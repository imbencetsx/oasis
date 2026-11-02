import CoreGraphics

/// Keeps page-local coordinates at the same scale and origin for a whole share.
struct WebViewCaptureFraming: Sendable {
    let width: Int
    let height: Int
    private let scale: CGFloat

    init(contentSize: CGSize) {
        scale = min(1, 1440 / max(1, contentSize.width))
        width = max(2, Int(contentSize.width * scale))
        height = max(2, Int(contentSize.height * scale))
    }

    func scaledSourceSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, Int(size.width * scale)), height: max(2, Int(size.height * scale)))
    }

    func imageOnFixedCanvas(_ image: CGImage, sourceSize: CGSize? = nil) -> CGImage? {
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
        let size = sourceSize ?? CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: CGFloat(height) - size.height,
                                      width: size.width, height: size.height))
        return context.makeImage()
    }
}
