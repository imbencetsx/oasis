import Foundation
import ImageIO
import AppKit

/// Sidebar icons need a small decoded bitmap, even when a site supplies a large image.
enum FaviconThumbnail {
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

/// Shared favicon download + decode used by tabs and the library icon cache.
enum FaviconLoader {
    static func download(_ iconURL: URL) async -> NSImage? {
        let client = URLSession(configuration: .ephemeral)
        defer { client.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await client.data(for: URLRequest(url: iconURL, timeoutInterval: 8))
            guard data.count <= 1_000_000,
                  let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
            let thumbnail = await Task.detached(priority: .utility) { FaviconThumbnail.decode(data) }.value
            if let thumbnail {
                return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
            // Preserve vector/other formats supported by AppKit but not ImageIO.
            return NSImage(data: data)
        } catch { return nil }
    }
}
