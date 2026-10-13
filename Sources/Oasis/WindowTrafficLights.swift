import AppKit
import QuartzCore

/// Keeps the real system buttons attached to their window while sliding with the sidebar.
@MainActor final class WindowTrafficLights {
  private struct ButtonState {
    let button: NSButton
    let transform: CATransform3D
    let wantsLayer: Bool
    let alpha: CGFloat
    let hidden: Bool
  }
  private let buttons: [ButtonState]
  private var visible: Bool?
  private var generation = 0

  init(window: NSWindow) {
    buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
      guard let button = window.standardWindowButton($0) else { return nil }
      let wantsLayer = button.wantsLayer
      button.wantsLayer = true
      return ButtonState(button: button, transform: button.layer?.transform ?? CATransform3DIdentity,
                         wantsLayer: wantsLayer, alpha: button.alphaValue, hidden: button.isHidden)
    }
  }

  func update(visible: Bool, animated: Bool, force: Bool = false) {
    guard force || self.visible != visible else { return }
    // AppKit can reset a hidden button's layer geometry. Opening still starts
    // from the collapsed sidebar position, while rapid reversals use presentation state.
    let starts = buttons.map { state in
      if self.visible == false && state.button.isHidden {
        return CATransform3DTranslate(state.transform, -224, 0, 0)
      }
      return state.button.layer?.presentation()?.transform ?? state.button.layer?.transform ?? state.transform
    }
    self.visible = visible
    generation += 1
    let currentGeneration = generation
    for state in buttons { state.button.isHidden = state.hidden }
    let apply: (Bool) -> Void = { [buttons] animate in
      for (state, from) in zip(buttons, starts) {
        let target = animate ? state.button.animator() : state.button
        target.alphaValue = visible ? state.alpha : 0
        if let layer = state.button.layer {
          let transform = visible ? state.transform : CATransform3DTranslate(state.transform, -224, 0, 0)
          layer.removeAnimation(forKey: "oasisSidebarSlide")
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          layer.transform = transform
          CATransaction.commit()
          if animate {
            let slide = CABasicAnimation(keyPath: "transform")
            slide.fromValue = NSValue(caTransform3D: from)
            slide.toValue = NSValue(caTransform3D: transform)
            slide.duration = 0.36
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(slide, forKey: "oasisSidebarSlide")
          }
        }
      }
    }
    guard animated else {
      apply(false)
      for state in buttons { state.button.isHidden = visible ? state.hidden : true }
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.36
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      apply(true)
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == currentGeneration else { return }
        for state in self.buttons { state.button.isHidden = visible ? state.hidden : true }
      }
    }
  }

  func restore() {
    generation += 1
    for state in buttons {
      state.button.layer?.removeAnimation(forKey: "oasisSidebarSlide")
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      state.button.layer?.transform = state.transform
      CATransaction.commit()
      state.button.alphaValue = state.alpha
      state.button.isHidden = state.hidden
      state.button.wantsLayer = state.wantsLayer
    }
    visible = nil
  }
}
