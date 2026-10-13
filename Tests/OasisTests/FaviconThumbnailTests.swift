import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Oasis

@Suite("Favicon memory")
struct FaviconThumbnailTests {
    @Test func largeSiteImagesBecomeSmallBitmapsWithoutChangingAspectRatio() throws {
        let width = 1024, height = 512
        let pixels = Data(repeating: 255, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let thumbnail = try #require(FaviconThumbnail.decode(encoded as Data))
        #expect(thumbnail.width == 64)
        #expect(thumbnail.height == 32)
        #expect(FaviconThumbnail.decode(Data("invalid image".utf8)) == nil)
    }
}
