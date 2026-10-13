import SwiftUI

/// A cached, static texture shared by the window background and sidebar.
struct BackgroundGrain: View {
  static let preferenceKey = "backgroundGrain"
  static let defaultIntensity = 0.2
  let intensity: Double

  static func normalized(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : defaultIntensity
  }

  var body: some View {
    if let image = Self.texture, Self.normalized(intensity) > 0 {
      Image(decorative: image, scale: 1)
        .resizable(resizingMode: .tile)
        .interpolation(.none)
        .blendMode(.softLight)
        .opacity(Self.normalized(intensity) * 0.32)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private static let texture: CGImage? = {
    let side = 128
    var state: UInt32 = 0x4D595DF4
    let pixels = (0..<(side * side)).map { _ -> UInt8 in
      state = state &* 1_664_525 &+ 1_013_904_223
      return UInt8(truncatingIfNeeded: state >> 24)
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }()
}
