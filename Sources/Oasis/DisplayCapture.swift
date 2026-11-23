import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// Captures one entire display (including the pointer) for a screen share.
/// Frames are JPEG-encoded off the main thread; the share bridge reads the latest.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Display: Hashable, Sendable { let id: CGDirectDisplayID; let name: String }

    /// Shared streams stay within this width; older Macs encode every frame on the CPU.
    static let maximumWidth: CGFloat = 1600
    static let framesPerSecond: Int32 = 20

    let size: CGSize
    private let lock = NSLock()
    private var latest: String?
    private var sequence = 0
    private var failure: String?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.oasis.display-capture", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    @MainActor static var displays: [Display] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName)
        }
    }

    private init(size: CGSize) {
        self.size = size
        super.init()
    }

    /// Starts capturing. Throws a readable error when Screen Recording is not allowed.
    static func start(displayID: CGDirectDisplayID) async throws -> DisplayCapture {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt (first time) or adds [oasis] to the list in Settings.
            _ = CGRequestScreenCaptureAccess()
            throw failure("Allow [oasis] under System Settings › Privacy & Security › Screen & System Audio Recording, then quit and reopen [oasis] and share again.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw failure("The display is no longer available.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let pixels = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, maximumWidth / max(1, pixels.width))
        let size = CGSize(width: max(2, (pixels.width * scale).rounded()), height: max(2, (pixels.height * scale).rounded()))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        let capture = DisplayCapture(size: size)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: capture)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        capture.stream = stream
        try await stream.startCapture()
        return capture
    }

    /// The latest encoded frame and its sequence number, or the reason capture stopped.
    var current: (frame: String?, sequence: Int, failure: String?) {
        lock.withLock { (latest, sequence, failure) }
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            defer { self.stream = nil }
            return self.stream
        }
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.7]
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else { return }
        let encoded = "data:image/jpeg;base64," + data.base64EncodedString()
        lock.withLock {
            latest = encoded
            sequence += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { failure = error.localizedDescription }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Oasis.ScreenSharing", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
