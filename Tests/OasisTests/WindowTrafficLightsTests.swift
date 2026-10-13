import AppKit
import QuartzCore
import Testing
@testable import Oasis

@Suite("Sidebar traffic lights", .serialized)
@MainActor struct WindowTrafficLightsTests {
  private func window() -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  @Test func collapsingHidesAllNativeButtonsAndRestoresTheirPositions() throws {
    let window = window()
    defer { window.close() }
    let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
      try #require(window.standardWindowButton($0))
    }
    let original = buttons.map { ($0.frame, $0.alphaValue, $0.isHidden, $0.isEnabled) }
    let lights = WindowTrafficLights(window: window)
    for _ in 0..<3 {
      lights.update(visible: false, animated: false)
      for button in buttons {
        #expect(button.isHidden && button.alphaValue == 0)
        #expect(button.layer?.transform.m41 == -224)
      }
      lights.update(visible: true, animated: false)
      for (index, button) in buttons.enumerated() {
        #expect(button.frame == original[index].0)
        #expect(button.alphaValue == original[index].1)
        #expect(button.isHidden == original[index].2)
        #expect(button.layer?.transform.m41 == 0)
        #expect(button.isEnabled == original[index].3)
      }
    }
  }

  @Test func animatedCollapseFinishesHiddenAndOpeningRestoresControls() async throws {
    let window = window()
    defer { window.close() }
    let close = try #require(window.standardWindowButton(.closeButton))
    let lights = WindowTrafficLights(window: window)
    lights.update(visible: false, animated: true)
    let slideOut = try #require(close.layer?.animation(forKey: "oasisSidebarSlide") as? CABasicAnimation)
    #expect((slideOut.toValue as? NSValue)?.caTransform3DValue.m41 == -224)
    for _ in 0..<80 {
      if close.isHidden && close.alphaValue == 0 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(close.isHidden && close.alphaValue == 0)
    lights.update(visible: true, animated: true)
    let slideIn = try #require(close.layer?.animation(forKey: "oasisSidebarSlide") as? CABasicAnimation)
    #expect((slideIn.fromValue as? NSValue)?.caTransform3DValue.m41 == -224)
    for _ in 0..<80 {
      if !close.isHidden && close.alphaValue == 1 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(!close.isHidden && close.alphaValue == 1)
    #expect(close.layer?.transform.m41 == 0)
    #expect(close.isEnabled)
  }

  @Test func rapidTogglingDoesNotLetOldAnimationHideVisibleButtons() async throws {
    let window = window()
    defer { window.close() }
    let close = try #require(window.standardWindowButton(.closeButton))
    let original = close.frame
    let lights = WindowTrafficLights(window: window)
    lights.update(visible: false, animated: true)
    lights.update(visible: true, animated: true)
    try await Task.sleep(for: .milliseconds(600))
    #expect(!close.isHidden)
    #expect(close.alphaValue == 1)
    #expect(close.frame == original)
    lights.update(visible: false, animated: false)
    lights.restore()
    #expect(!close.isHidden && close.frame == original)
  }

  @Test func windowResizeKeepsControlsHiddenAndCloseCallbackWorks() throws {
    let window = window()
    var didClose = false
    let observer = CloseObserverView { didClose = true }
    observer.configureTrafficLights(showsSidebar: false, reduceMotion: true)
    window.contentView = observer
    let close = try #require(window.standardWindowButton(.closeButton))
    #expect(close.isHidden)
    window.setContentSize(NSSize(width: 1000, height: 650))
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    #expect(close.isHidden)
    observer.configureTrafficLights(showsSidebar: true, reduceMotion: true)
    #expect(!close.isHidden)
    window.close()
    #expect(didClose)
  }
}
