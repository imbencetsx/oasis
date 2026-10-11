import SwiftUI

/// Small, interruptible spring feedback; native controls still own clicks and keyboard activation.
struct OasisButtonStyle: ButtonStyle {
  var pressScale: CGFloat = 0.94
  var hoverScale: CGFloat = 1.025
  var tilt: Double = 0.7

  func makeBody(configuration: Configuration) -> some View {
    Feedback(configuration: configuration, pressScale: pressScale, hoverScale: hoverScale, tilt: tilt)
  }

  private struct Feedback: View {
    let configuration: Configuration
    let pressScale: CGFloat
    let hoverScale: CGFloat
    let tilt: Double
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      configuration.label
        .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? pressScale : hovering ? hoverScale : 1)
        .rotationEffect(.degrees(reduceMotion || !isEnabled ? 0 : configuration.isPressed ? -tilt : 0))
        .opacity(isEnabled ? 1 : 0.4)
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.28), value: configuration.isPressed)
        .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
  }
}
