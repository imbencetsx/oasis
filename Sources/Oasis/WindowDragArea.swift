import AppKit
import SwiftUI

/// Only this explicit chrome region moves the window. Text inputs and controls stay interactive.
struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> ChromeDragView { ChromeDragView() }
  func updateNSView(_ nsView: ChromeDragView, context: Context) {}
}

final class ChromeDragView: NSView {
  override var isOpaque: Bool { false }
  override var mouseDownCanMoveWindow: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}
